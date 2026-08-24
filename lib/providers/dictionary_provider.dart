import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

      // My per-device wrap first; fall back to the pre-registry legacy
      // wrap ("default" slot) when it was made against this device's key
      // — same seed → same public key → adopted version matches.
      final myWrap = context.wraps[myMember.key] ??
          _legacyWrapFor(context, myMember, deviceId);
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

      final usedLegacyWrap = !context.wraps.containsKey(myMember.key);
      Uint8List chatKey;
      List<DictEntry> entries;
      try {
        chatKey = await crypto.unwrapChatKey(
          myKeyPair: myKey,
          wrap: myWrap,
        );
        entries = await crypto.decryptEntries(
          ciphertext: context.ciphertext!,
          iv: context.iv!,
          authTag: context.authTag!,
          chatKey: chatKey,
        );
      } catch (e) {
        debugPrint(
          'dictionary[$chatId]: decrypt via '
          '${usedLegacyWrap ? 'legacy' : 'per-device'} wrap FAILED: $e',
        );
        // We hold a valid server context but cannot decrypt with any wrap
        // we have — the chat key is lost to this device (and per the
        // coverage checks, everyone else's too). Surface the Start-over
        // path instead of a dead zombie; version/participants/wraps are
        // kept so reset() can re-key and save for everyone.
        _chatKey = null;
        state = DictionaryState(
          isLoading: false,
          entries: const [],
          version: context.version,
          participants: context.participants,
          wraps: context.wraps,
          needsRekey: true,
          hasDictionary: true,
          error: 'This dictionary can’t be decrypted anymore — start over.',
        );
        return;
      }

      _chatKey = chatKey;
      // Remember the key so this device can self-heal if its wrap goes
      // stale later (another device re-registering its public key). Only
      // cached after it proved able to decrypt the blob.
      try {
        await crypto.cacheChatKey(chatId, chatKey);
      } catch (_) {
        // Secure storage unavailable — device just can't self-heal.
      }

      state = DictionaryState(
        isLoading: false,
        entries: entries,
        version: context.version,
        participants: context.participants,
        wraps: context.wraps,
        needsRekey: false,
        hasDictionary: true,
      );
      debugPrint(
        'dictionary[$chatId]: loaded hasDict=true v=${context.version} '
        'participants=${context.participants.length}',
      );
      try {
        await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
      } on StateError {
        // Provider disposed mid-write — fine.
      }
    } catch (e) {
      debugPrint('dictionary[$chatId]: LOAD FAILED: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Could not load dictionary ($e)',
      );
    }
  }

  Future<void> reload() => _load();

  /// The pre-registry wrap (`userId:default`), but only when it was made
  /// against this device's key — i.e. this device adopted the legacy slot
  /// and its version matches. Returns null otherwise.
  DictionaryWrap? _legacyWrapFor(
    DictionaryContext context,
    DictionaryMember me,
    String deviceId,
  ) {
    final legacy = context.wraps['${me.userId}:default'];
    if (legacy == null) return null;
    if (legacy.deviceKeyVersion != me.encPublicKeyVersion) {
      debugPrint(
        'dictionary: legacy wrap for ${me.userId} is v${legacy.deviceKeyVersion}, '
        'this device is v${me.encPublicKeyVersion} — not usable',
      );
      return null;
    }
    debugPrint(
      'dictionary: using pre-registry legacy wrap for ${me.userId} on $deviceId',
    );
    return legacy;
  }

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
        debugPrint('dictionary[$chatId]: cached chat key failed to decrypt — dropping it');
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
        debugPrint('dictionary[$chatId]: self-heal re-keyed at v${saved.version}');
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
        debugPrint(
          'dictionary[$chatId]: self-heal save rejected (${e.statusCode}) ${e.message}',
        );
        if (e.statusCode != 409) return false;
        // A concurrent save won — take the freshest blob and retry once.
        current = await repo.getDictionary(chatId);
      } catch (e) {
        debugPrint('dictionary[$chatId]: self-heal failed: $e');
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
    debugPrint(
      'dictionary[$chatId]: wrapping ${participants.length} participants '
      'with ${wraps.length} wraps at v$version',
    );
    final savedVersion = await repo.saveDictionary(
      chatId: chatId,
      version: version,
      ciphertext: ciphertext,
      iv: iv,
      authTag: authTag,
      wraps: wraps,
    );
    debugPrint(
      'dictionary[$chatId]: wrapped ${participants.length} participants '
      'with ${wraps.length} wraps at v$savedVersion',
    );
    return (
      version: savedVersion,
      wraps: {for (final w in wraps) w.key: w},
    );
  }

  /// Re-keys a dead dictionary from scratch: fresh chat key, [entries]
  /// encrypted under it, wraps for every current participant device. This
  /// is the migration path for chats no device can decrypt anymore
  /// (`needsRekey`): the old code words are gone, but the chat keeps
  /// working with whatever the user re-enters. Returns the saved entries.
  Future<({bool ok, String? error, List<DictEntry>? entries})> reset(
    List<DictEntry> entries,
  ) async {
    try {
      if (state.isLoading) {
        return (ok: false, error: 'Dictionary still loading', entries: null);
      }
      if (!state.needsRekey) {
        return (
          ok: false,
          error: 'Dictionary is still readable — nothing to reset',
          entries: null,
        );
      }
      debugPrint(
        'dictionary[$chatId]: reset — creating a new chat key at v${state.version + 1}',
      );
      final crypto = ref.read(dictionaryCryptoProvider);
      _chatKey = Uint8List.fromList(await crypto.createChatKey());
      try {
        await crypto.cacheChatKey(chatId, _chatKey!);
      } catch (_) {}
      final blob = await crypto.encryptEntries(
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
      debugPrint('dictionary[$chatId]: reset complete at v${saved.version}');
      try {
        await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
      } on StateError {
        // Dispose race — ignore.
      }
      return (ok: true, error: null, entries: entries);
    } on ApiException catch (e) {
      debugPrint('dictionary[$chatId]: reset rejected (${e.statusCode}) ${e.message}');
      return (
        ok: false,
        error: e.statusCode == 422
            ? 'Member list changed — please try again'
            : 'Could not reset dictionary: ${e.message}',
        entries: null,
      );
    } catch (err) {
      debugPrint('dictionary[$chatId]: reset failed: $err');
      return (ok: false, error: 'Could not reset dictionary: $err', entries: null);
    }
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
        if (!state.hasDictionary && state.error != null) {
          // Zombie state: the last load failed (version 0, no participants)
          // — any save from here would write a blob with zero wraps that
          // can never pass coverage, even if an old chat key lingers.
          debugPrint(
            'dictionary[$chatId]: refusing to save from a failed-load state',
          );
          return (
            ok: false,
            error: 'Dictionary failed to load — close and reopen this screen',
            entries: null,
          );
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
        debugPrint('dictionary: save rejected (${e.statusCode}) ${e.message}');
        // 409 = a concurrent save won (merge + retry). 422 = our wrap set
        // didn't cover someone (stale participant view) — reload and retry
        // once with fresh participants, but don't merge. Anything else is
        // surfaced raw so real problems aren't masked by a generic message.
        final retryable = e.statusCode == 409 || e.statusCode == 422;
        if (!retryable) {
          return (
            ok: false,
            error: 'Could not save dictionary: ${e.message}',
            entries: null,
          );
        }
        if (attempt == 2) {
          return (
            ok: false,
            error: e.statusCode == 409
                ? 'Dictionary changed too many times — please try again'
                : 'Could not save dictionary: ${e.message}',
            entries: null,
          );
        }
        // A concurrent save won or our coverage went stale: reload the
        // freshest version and retry with new participants/version.
        await _load();
        if (state.needsRekey) {
          return (
            ok: false,
            error: 'Dictionary was re-keyed by another member — cannot merge',
            entries: null,
          );
        }
        if (e.statusCode == 409) {
          entries = DictionaryCrypto.mergeDictionaryEntries(
            remote: state.entries,
            local: entries,
          );
        }
      } catch (err, st) {
        debugPrint('dictionary: save failed: $err\n$st');
        return (
          ok: false,
          error: 'Could not save dictionary: $err',
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