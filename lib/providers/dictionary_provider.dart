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
    this.isLocked = false,
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

  /// True when the dictionary is passphrase-locked and this session has
  /// not unlocked it yet: entries are unavailable, tap-to-reveal and the
  /// dictionary screen are gated behind [DictionaryController.unlock].
  final bool isLocked;

  final String? error;

  DictionaryState copyWith({
    bool? isLoading,
    List<DictEntry>? entries,
    int? version,
    List<DictionaryMember>? participants,
    Map<String, DictionaryWrap>? wraps,
    bool? needsRekey,
    bool? hasDictionary,
    bool? isLocked,
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
        isLocked: isLocked ?? this.isLocked,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Loads, decrypts and saves a chat's dictionary. Crypto is purely
/// device-local ([DictionaryCrypto]); the repository moves opaque blobs.
/// The chat AES key lives in memory while loaded and is mirrored into
/// secure storage so a stale wrap can self-heal without another member.
///
/// Passphrase-locked ("locked-v1") dictionaries replace the chat key with
/// a key derived from a shared passphrase. The derived key ([_lockKey])
/// and its metadata live in memory ONLY — every app launch starts locked
/// again, and nothing passphrase-related is ever persisted.
class DictionaryController
    extends AutoDisposeFamilyNotifier<DictionaryState, String> {
  Uint8List? _chatKey;

  /// Derived lock key of a locked dictionary while the session holds it.
  Uint8List? _lockKey;

  /// KDF metadata of the locked variant this controller is working with
  /// (set on unlock / create / rotate; cleared when a legacy blob loads).
  DictionaryLockMeta? _activeLockMeta;

  /// Raw locked blob awaiting a passphrase (non-null ⇔ locked & not yet
  /// unlocked this session).
  DictionaryContext? _lockedContext;

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

      // Passphrase-locked ("locked-v1") dictionaries never touch the
      // device-key/wrap machinery below — access is the passphrase alone.
      if (context.isLocked) {
        await _applyLockedContext(context);
        return;
      }
      _activeLockMeta = null;
      _lockedContext = null;

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

  // ── Passphrase lock ("locked-v1") ──────────────────────────────────────

  /// Enters the locked branch: purge any cached plaintext (a stale cache
  /// must not leak meanings while the chat is locked), then either
  /// re-decrypt with this session's key or park the blob until
  /// [unlock] is called.
  Future<void> _applyLockedContext(DictionaryContext context) async {
    try {
      await ref.read(chatCacheProvider).deleteDictionary(chatId);
    } catch (_) {}
    _chatKey = null;
    _activeLockMeta = context.lock;

    final key = _lockKey;
    if (key != null) {
      try {
        final entries = await ref.read(dictionaryCryptoProvider).decryptEntries(
              ciphertext: context.ciphertext!,
              iv: context.iv!,
              authTag: context.authTag!,
              chatKey: key,
            );
        _lockedContext = null;
        state = DictionaryState(
          isLoading: false,
          entries: entries,
          version: context.version,
          participants: context.participants,
          hasDictionary: true,
        );
        _cacheUnlocked(entries);
        return;
      } catch (_) {
        // The blob was re-keyed (e.g. an owner reset) — our session key is
        // dead; drop it and show the locked state again.
        debugPrint('dictionary[$chatId]: session lock key no longer decrypts — re-locking');
        _lockKey = null;
      }
    }

    _lockedContext = context;
    state = DictionaryState(
      isLoading: false,
      entries: const [],
      version: context.version,
      participants: context.participants,
      wraps: const {},
      needsRekey: false,
      hasDictionary: true,
      isLocked: true,
    );
  }

  Future<void> _cacheUnlocked(List<DictEntry> entries) async {
    try {
      await ref.read(chatCacheProvider).writeDictionary(chatId, entries);
    } on StateError {
      // Provider disposed mid-write — fine.
    }
  }

  /// Attempts to unlock the locked dictionary with [passphrase]. A wrong
  /// passphrase fails GCM authentication and surfaces as an error — there
  /// is no attempt limiting (the secret strength IS the limit).
  Future<({bool ok, String? error})> unlock(String passphrase) async {
    final context = _lockedContext;
    if (context == null || !context.isLocked) {
      return (ok: false, error: 'Nothing to unlock');
    }
    if (passphrase.isEmpty) {
      return (ok: false, error: 'Enter the passphrase');
    }
    final crypto = ref.read(dictionaryCryptoProvider);
    try {
      final key = await crypto.deriveLockKey(
        passphrase: passphrase,
        meta: context.lock!,
      );
      final entries = await crypto.decryptEntries(
        ciphertext: context.ciphertext!,
        iv: context.iv!,
        authTag: context.authTag!,
        chatKey: key,
      );
      _lockKey = key;
      _activeLockMeta = context.lock;
      _lockedContext = null;
      state = DictionaryState(
        isLoading: false,
        entries: entries,
        version: context.version,
        participants: context.participants,
        hasDictionary: true,
      );
      _cacheUnlocked(entries);
      debugPrint('dictionary[$chatId]: unlocked at v${context.version}');
      return (ok: true, error: null);
    } catch (e) {
      debugPrint('dictionary[$chatId]: unlock failed (wrong passphrase?)');
      return (ok: false, error: 'Wrong passphrase');
    }
  }

  /// Drops the session's unlocked state; the next load returns to locked.
  Future<void> lock() async {
    if (_lockKey == null && !state.hasDictionary) return;
    _lockKey = null;
    await reload();
  }

  /// Owner reset while locked: sets a NEW passphrase without knowing the
  /// old one. Authority comes from membership/admin, not the secret, so
  /// the dictionary starts over with empty entries — everyone must enter
  /// the new passphrase and re-add their code words.
  Future<({bool ok, String? error})> resetLockKey(String newPassphrase) async {
    final repo = ref.read(dictionaryRepositoryProvider);
    final crypto = ref.read(dictionaryCryptoProvider);
    final context = _lockedContext;
    if (context == null || !context.isLocked) {
      return (ok: false, error: 'Dictionary is not locked');
    }
    if (newPassphrase.isEmpty) {
      return (ok: false, error: 'Enter a new passphrase');
    }
    try {
      final meta = await crypto.createLockMeta();
      final key = await crypto.deriveLockKey(
        passphrase: newPassphrase,
        meta: meta,
      );
      final blob =
          await crypto.encryptEntries(entries: const [], chatKey: key);
      final version = await repo.saveDictionary(
        chatId: chatId,
        version: context.version + 1,
        ciphertext: blob.ciphertext,
        iv: blob.iv,
        authTag: blob.authTag,
        lock: meta,
      );
      _lockKey = key;
      _activeLockMeta = meta;
      _lockedContext = null;
      state = DictionaryState(
        isLoading: false,
        entries: const [],
        version: version,
        participants: context.participants,
        hasDictionary: true,
      );
      debugPrint('dictionary[$chatId]: lock key reset at v$version');
      return (ok: true, error: null);
    } on ApiException catch (e) {
      debugPrint('dictionary[$chatId]: lock reset rejected (${e.statusCode})');
      return (
        ok: false,
        error: e.statusCode == 409
            ? 'Dictionary changed — please try again'
            : 'Could not reset lock: ${e.message}',
      );
    } catch (e) {
      debugPrint('dictionary[$chatId]: lock reset failed: $e');
      return (ok: false, error: 'Could not reset lock: $e');
    }
  }

  /// Opts a legacy (wrap-based) dictionary into the lock: re-encrypts the
  /// current entries under a passphrase-derived key and drops the wraps.
  /// Requires a decrypted session ([state.entries] populated).
  Future<({bool ok, String? error})> addLock(String passphrase) async {
    if (!state.hasDictionary || state.isLocked) {
      return (ok: false, error: 'No unlockable dictionary to lock');
    }
    if (state.needsRekey) {
      return (ok: false, error: 'Fix the dictionary first (start over)');
    }
    if (passphrase.isEmpty) {
      return (ok: false, error: 'Enter a passphrase');
    }
    try {
      final saved = await _saveLocked(
        [for (final e in state.entries) if (e.isValid) e],
        passphrase: passphrase,
      );
      debugPrint('dictionary[$chatId]: lock added at v${saved.version}');
      return (ok: true, error: null);
    } catch (e) {
      debugPrint('dictionary[$chatId]: addLock failed: $e');
      return (ok: false, error: 'Could not add lock: $e');
    }
  }

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

  /// Locked-variant save: encrypts [entries] under the session lock key
  /// (or one freshly derived from [passphrase]) and PUTs a "locked-v1"
  /// payload — no wraps, no coverage. On a 409 the freshest blob is
  /// fetched, merged and retried (the other member must have used the
  /// same passphrase to save at all).
  Future<({int version, List<DictEntry> entries})> _saveLocked(
    List<DictEntry> entries, {
    String? passphrase,
  }) async {
    final crypto = ref.read(dictionaryCryptoProvider);
    final repo = ref.read(dictionaryRepositoryProvider);

    var meta = _activeLockMeta;
    var key = _lockKey;
    if (key == null || meta == null) {
      if (passphrase == null || passphrase.isEmpty) {
        throw StateError('A locked save needs the lock passphrase');
      }
      meta = await crypto.createLockMeta();
      key = await crypto.deriveLockKey(passphrase: passphrase, meta: meta);
    }

    var merged = entries;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final blob =
            await crypto.encryptEntries(entries: merged, chatKey: key);
        final version = await repo.saveDictionary(
          chatId: chatId,
          version: state.version + 1,
          ciphertext: blob.ciphertext,
          iv: blob.iv,
          authTag: blob.authTag,
          lock: meta,
        );
        _lockKey = key;
        _activeLockMeta = meta;
        state = DictionaryState(
          isLoading: false,
          entries: merged,
          version: version,
          participants: state.participants,
          hasDictionary: true,
        );
        _cacheUnlocked(merged);
        return (version: version, entries: merged);
      } on ApiException catch (e) {
        if (e.statusCode != 409 || attempt == 2) rethrow;
        debugPrint(
          'dictionary[$chatId]: locked save hit a conflict (${e.message}) — merging',
        );
        await _load();
        if (state.isLocked) {
          // The winner used a DIFFERENT passphrase (owner reset) — our
          // session key can't read their blob anymore.
          throw StateError('The lock was changed by another member');
        }
        merged = DictionaryCrypto.mergeDictionaryEntries(
          remote: state.entries,
          local: merged,
        );
      }
    }
    throw ApiException(
      409,
      'Dictionary changed too many times — please try again',
    );
  }

  /// Saves [entries]: re-encrypts under the chat key (creating it on first
  /// use), wraps for every participant with a public key, then PUTs.
  /// After a save all current members are rewrapped.
  ///
  /// Passphrase-locked dictionaries take the [DictionaryController._saveLocked]
  /// path instead: [lockPassphrase] must be supplied when CREATING a new
  /// locked dictionary (there is no session key yet); afterwards the
  /// in-memory session key suffices until the next app launch.
  ///
  /// When a concurrent save wins (backend 409 version conflict), reloads the
  /// freshest dictionary, merges [entries] on top ([mergeDictionaryEntries]),
  /// and retries — so both members keep their edits. Returns the final saved
  /// entry set via `entries` so callers can sync their local copy.
  Future<({bool ok, String? error, List<DictEntry>? entries})> save(
    List<DictEntry> entries, {
    String? lockPassphrase,
  }) async {
    if (state.isLocked) {
      return (
        ok: false,
        error: 'Unlock the dictionary with the passphrase first',
        entries: null,
      );
    }
    final useLock = _activeLockMeta != null ||
        (lockPassphrase != null && lockPassphrase.isNotEmpty);
    if (useLock && _lockKey == null && (lockPassphrase == null || lockPassphrase.isEmpty)) {
      return (
        ok: false,
        error: 'Set a lock passphrase to create the dictionary',
        entries: null,
      );
    }
    if (useLock) {
      try {
        final saved = await _saveLocked(
          [for (final e in entries) if (e.isValid) e],
          passphrase: lockPassphrase,
        );
        return (ok: true, error: null, entries: saved.entries);
      } on ApiException catch (e) {
        debugPrint('dictionary[$chatId]: locked save rejected (${e.statusCode})');
        return (
          ok: false,
          error: e.statusCode == 409
              ? 'Dictionary changed too many times — please try again'
              : 'Could not save dictionary: ${e.message}',
          entries: null,
        );
      } catch (err) {
        debugPrint('dictionary[$chatId]: locked save failed: $err');
        return (ok: false, error: 'Could not save dictionary: $err', entries: null);
      }
    }
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