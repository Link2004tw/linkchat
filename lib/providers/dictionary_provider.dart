import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/dictionary.dart';
import '../services/dictionary_crypto.dart';
import 'auth_providers.dart';
import 'chat_list_provider.dart';
import 'repository_providers.dart';

/// State of one chat's encrypted dictionary.
class DictionaryState {
  const DictionaryState({
    this.isLoading = true,
    this.entries = const [],
    this.version = 0,
    this.participants = const [],
    this.wraps = const {},
    this.needsRekey = false,
    this.hasDictionary = false,
    this.error,
  });

  final bool isLoading;
  final List<DictEntry> entries;
  final int version;
  final List<DictionaryMember> participants;

  /// userId → wrap (needed to compute member wrap status in the UI).
  final Map<String, DictionaryWrap> wraps;

  /// True when this device has no current wrap AND no cached chat key,
  /// so it cannot read or re-encrypt the dictionary until someone rewraps.
  final bool needsRekey;

  /// Whether a dictionary exists server-side (false = lazy init not done).
  final bool hasDictionary;

  final String? error;

  DictionaryState copyWith({
    bool? isLoading,
    List<DictEntry>? entries,
    int? version,
    List<DictionaryMember>? participants,
    Map<String, DictionaryWrap>? wraps,
    bool? needsRekey,
    bool? hasDictionary,
    bool clearError = false,
    String? error,
  }) =>
      DictionaryState(
        isLoading: isLoading ?? this.isLoading,
        entries: entries ?? this.entries,
        version: version ?? this.version,
        participants: participants ?? this.participants,
        wraps: wraps ?? this.wraps,
        needsRekey: needsRekey ?? this.needsRekey,
        hasDictionary: hasDictionary ?? this.hasDictionary,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Loads, decrypts and saves a chat's dictionary. Crypto is purely
/// device-local ([DictionaryCrypto]); the repository moves opaque blobs.
/// The chat AES key lives in memory while loaded and is mirrored into
/// secure storage so a stale wrap can self-heal without another member.
class DictionaryController
    extends AutoDisposeFamilyNotifier<DictionaryState, String> {
  Uint8List? _chatKey;

  /// In-flight guard so concurrent reloads (WS `dictionary-update` pings,
  /// conflict retries) share one `_load` instead of racing each other.
  Future<void>? _loading;

  String get chatId => arg;

  @override
  DictionaryState build(String chatId) {
    // Offline: seed from cache so the chat still shows codes.
    final cached = ref.read(chatCacheProvider).readDictionary(chatId);
    final initial = cached == null
        ? const DictionaryState()
        : DictionaryState(
            isLoading: true,
            entries:
                cached.map(DictEntry.fromJson).toList(growable: false),
            hasDictionary: true,
          );
    state = initial;
    _load();
    return state;
  }

  /// Loads (and decrypts) the dictionary. Safe to call multiple times —
  /// used on provider init and on WS `dictionary-update` pings.
  Future<void> _load() => _loading ??= _doLoad().whenComplete(() => _loading = null);

  Future<void> _doLoad() async {
    try {
      final crypto = ref.read(dictionaryCryptoProvider);
      final repo = ref.read(dictionaryRepositoryProvider);
      final me = ref.read(currentUserProvider);
      final myClerkId = me?.clerkId;
      if (myClerkId == null) return;

      // Ensure this device's keypair + stable id are registered so peers
      // can wrap the chat key for this device specifically.
      final myKey = await crypto.ensureKeyPair();
      final myPub = base64Encode(
        (await myKey.extractPublicKey()).bytes,
      );
      final deviceId = await crypto.ensureDeviceId();
      final myDevices = await repo.getMyDevices();
      final mine = myDevices.where((d) => d.deviceId == deviceId).toList();
      if (mine.isEmpty || mine.first.encPublicKey != myPub) {
        await repo.registerPublicKey(myPub, deviceId);
      }

      final context = await repo.getDictionary(chatId);

      // Find my device's entry (participants are per member-device).
      final myMember = context.memberFor(myClerkId, deviceId);

      if (!context.exists || myMember == null) {
        // Lazy init: no dictionary yet — nothing to decrypt.
        _chatKey = null;
        state = DictionaryState(
          isLoading: false,
          entries: const [],
          version: 0,
          participants: context.participants,
          wraps: context.wraps,
          needsRekey: false,
          hasDictionary: false,
        );
        return;
      }

      final myWrap = context.wraps[myMember.key];
      if (myWrap == null ||
          myWrap.deviceKeyVersion != myMember.encPublicKeyVersion) {
        // My wrap is missing/stale — try self-healing from the cached key
        // (re-wrap for everyone and bump the version) before asking a
        // member to re-key manually.
        if (await _trySelfRekey(context)) return;
        _chatKey = null;
        state = DictionaryState(
          isLoading: false,
          entries: const [],
          version: context.version,
          participants: context.participants,
          wraps: context.wraps,
          needsRekey: context.exists,
          hasDictionary: true,
          error: 'Dictionary unreadable — ask a member to re-key it',
        );
        return;
      }

      final chatKey = await crypto.unwrapChatKey(
        myKeyPair: myKey,
        wrap: myWrap,
      );
      _chatKey = chatKey;
      // Remember the key so this device can self-heal if its wrap goes
      // stale later (another device re-registering its public key).
      try {
        await crypto.cacheChatKey(chatId, chatKey);
      } catch (_) {
        // Secure storage unavailable — device just can't self-heal.
      }
      final entries = await crypto.decryptEntries(
        ciphertext: context.ciphertext!,
        iv: context.iv!,
        authTag: context.authTag!,
        chatKey: chatKey,
      );

      state = DictionaryState(
        isLoading: false,
        entries: entries,
        version: context.version,
        participants: context.participants,
        wraps: context.wraps,
        needsRekey: false,
        hasDictionary: true,
      );
      try {
        await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
      } on StateError {
        // Provider disposed mid-write — fine.
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Could not load dictionary ($e)',
      );
    }
  }

  Future<void> reload() => _load();

  /// Attempts to recover from a missing/stale wrap using the chat key
  /// cached in secure storage from a previous successful open: decrypts
  /// the current blob (GCM auth proves the key is right), re-wraps for
  /// every participant and saves at version + 1. Returns true when the
  /// state was fully recovered; false leaves the manual re-key flow.
  Future<bool> _trySelfRekey(DictionaryContext context) async {
    final crypto = ref.read(dictionaryCryptoProvider);
    final repo = ref.read(dictionaryRepositoryProvider);

    Uint8List? cached;
    try {
      cached = await crypto.getCachedChatKey(chatId);
    } catch (_) {
      return false;
    }
    if (cached == null) return false;

    var current = context;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!current.exists) return false;
      List<DictEntry> entries;
      try {
        entries = await crypto.decryptEntries(
          ciphertext: current.ciphertext!,
          iv: current.iv!,
          authTag: current.authTag!,
          chatKey: cached,
        );
      } catch (_) {
        // Wrong/stale cached key — drop it and fall back to manual re-key.
        try {
          await crypto.clearCachedChatKey(chatId);
        } catch (_) {}
        return false;
      }
      _chatKey = cached;
      try {
        final saved = await _wrapAndSave(
          participants: current.participants,
          ciphertext: current.ciphertext!,
          iv: current.iv!,
          authTag: current.authTag!,
          version: current.version + 1,
        );
        state = DictionaryState(
          isLoading: false,
          entries: entries,
          version: saved.version,
          participants: current.participants,
          wraps: saved.wraps,
          needsRekey: false,
          hasDictionary: true,
        );
        try {
          await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
        } on StateError {
          // Provider disposed mid-write — fine.
        }
        return true;
      } on ApiException catch (e) {
        if (e.statusCode != 409) return false;
        // A concurrent save won — take the freshest blob and retry once.
        current = await repo.getDictionary(chatId);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Wraps [_chatKey] for every entry in [participants] with a public key
  /// and PUTs the dictionary blob at [version]. Returns the saved version +
  /// the fresh wraps (userId → wrap) for updating local state.
  Future<({int version, Map<String, DictionaryWrap> wraps})> _wrapAndSave({
    required List<DictionaryMember> participants,
    required String ciphertext,
    required String iv,
    required String authTag,
    required int version,
  }) async {
    final crypto = ref.read(dictionaryCryptoProvider);
    final repo = ref.read(dictionaryRepositoryProvider);
    final wraps = <DictionaryWrap>[];
    for (final member in participants) {
      if (!member.hasPublicKey) continue;
      wraps.add(await crypto.wrapChatKey(
        chatKey: _chatKey!,
        memberUserId: member.userId,
        deviceId: member.deviceId,
        deviceKeyVersion: member.encPublicKeyVersion,
        memberPubBase64: member.encPublicKey,
      ));
    }
    final savedVersion = await repo.saveDictionary(
      chatId: chatId,
      version: version,
      ciphertext: ciphertext,
      iv: iv,
      authTag: authTag,
      wraps: wraps,
    );
    return (
      version: savedVersion,
      wraps: {for (final w in wraps) w.key: w},
    );
  }

  /// Saves [entries]: re-encrypts under the chat key (creating it on first
  /// use), wraps for every participant with a public key, then PUTs.
  /// After a save all current members are rewrapped.
  ///
  /// When a concurrent save wins (backend 409 version conflict), reloads the
  /// freshest dictionary, merges [entries] on top ([mergeDictionaryEntries]),
  /// and retries — so both members keep their edits. Returns the final saved
  /// entry set via `entries` so callers can sync their local copy.
  Future<({bool ok, String? error, List<DictEntry>? entries})> save(
    List<DictEntry> entries,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (state.isLoading) {
          return (ok: false, error: 'Dictionary still loading', entries: null);
        }
        if (!state.hasDictionary && _chatKey == null) {
          _chatKey = Uint8List.fromList(await ref
              .read(dictionaryCryptoProvider)
              .createChatKey());
        }
        if (state.hasDictionary && _chatKey == null) {
          // Last resort: a key cached by an earlier successful open.
          try {
            _chatKey =
                await ref.read(dictionaryCryptoProvider).getCachedChatKey(chatId);
          } catch (_) {
            _chatKey = null;
          }
        }
        if (state.hasDictionary && _chatKey == null) {
          return (ok: false, error: 'Cannot re-encrypt: no chat key', entries: null);
        }

        final blob = await ref.read(dictionaryCryptoProvider).encryptEntries(
              entries: entries,
              chatKey: _chatKey!,
            );

        final saved = await _wrapAndSave(
          participants: state.participants,
          ciphertext: blob.ciphertext,
          iv: blob.iv,
          authTag: blob.authTag,
          version: state.version + 1,
        );

        state = DictionaryState(
          isLoading: false,
          entries: entries,
          version: saved.version,
          participants: state.participants,
          wraps: saved.wraps,
          needsRekey: false,
          hasDictionary: true,
        );
        try {
          await ref
              .read(dictionaryCryptoProvider)
              .cacheChatKey(chatId, _chatKey!);
        } catch (_) {
          // Secure storage unavailable — self-heal just won't work here.
        }
        try {
          await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
        } on StateError {
          // Dispose race — ignore.
        }
        return (ok: true, error: null, entries: entries);
      } on ApiException catch (e) {
        if (e.statusCode != 409) {
          return (
            ok: false,
            error: 'Could not save dictionary: $e',
            entries: null,
          );
        }
        if (attempt == 2) {
          return (
            ok: false,
            error: 'Dictionary changed too many times — please try again',
            entries: null,
          );
        }
        // A concurrent save won: reload the freshest version, merge this
        // device's pending edits on top, and retry with the new version.
        await _load();
        if (state.needsRekey) {
          return (
            ok: false,
            error: 'Dictionary was re-keyed by another member — cannot merge',
            entries: null,
          );
        }
        entries = DictionaryCrypto.mergeDictionaryEntries(
          remote: state.entries,
          local: entries,
        );
      } catch (e) {
        return (
          ok: false,
          error: 'Could not save dictionary: $e',
          entries: null,
        );
      }
    }
    return (
      ok: false,
      error: 'Dictionary changed too many times — please try again',
      entries: null,
    );
  }
}

final dictionaryProvider = NotifierProvider.autoDispose
    .family<DictionaryController, DictionaryState, String>(
  DictionaryController.new,
);