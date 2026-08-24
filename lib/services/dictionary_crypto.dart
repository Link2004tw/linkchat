import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/dictionary.dart';

/// Everything about the encrypted per-chat dictionary lives client-side:
/// each device generates an X25519 keypair (seed in secure storage), the
/// shared chat AES key is wrapped per-member with X25519 + AES-GCM, and the
/// dictionary entries are AES-256-GCM ciphertext under that chat key. This
/// class owns the crypto; it never talks to the network.
class DictionaryCrypto {
  DictionaryCrypto({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _seedKey = 'dict_x25519_seed';
  static const String _chatKeyPrefix = 'dict_chatkey_';

  final FlutterSecureStorage _storage;

  static final X25519 _x25519 = X25519();
  static final AesGcm _aes = AesGcm.with256bits();

  // ── Device key pair ──────────────────────────────────────────────────

  /// Returns this device's X25519 keypair, generating + persisting it on
  /// first call. The seed never leaves secure storage.
  Future<SimpleKeyPair> ensureKeyPair() async {
    final existing = await _storage.read(key: _seedKey);
    if (existing != null && existing.isNotEmpty) {
      final seed = base64Decode(existing);
      return _x25519.newKeyPairFromSeed(seed);
    }
    final pair = await _x25519.newKeyPair();
    final seed = (pair as SimpleKeyPairData).bytes;
    await _storage.write(key: _seedKey, value: base64Encode(seed));
    return pair;
  }

  Future<Uint8List> _sharedWithEphemeral(
    SimpleKeyPair ephemeral,
    SimplePublicKey remotePub,
  ) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remotePub,
    );
    final bytes = await secret.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<SecretKey> _aesKey(Uint8List raw) =>
      Future.value(SecretKeyData(raw));

  /// Creates a fresh 32-byte chat key.
  Future<List<int>> createChatKey() async {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  // ── Chat-key cache (secure storage, per chat) ────────────────────────

  /// Persists [chatKey] for [chatId] so this device can re-key itself when
  /// its wrap goes stale (e.g. after another device re-registered its
  /// public key). Same trust level as the device seed already stored here.
  Future<void> cacheChatKey(String chatId, List<int> chatKey) async {
    await _storage.write(
      key: '$_chatKeyPrefix$chatId',
      value: base64Encode(chatKey),
    );
  }

  /// Returns the cached chat key for [chatId], or null when none stored.
  Future<Uint8List?> getCachedChatKey(String chatId) async {
    final stored = await _storage.read(key: '$_chatKeyPrefix$chatId');
    if (stored == null || stored.isEmpty) return null;
    try {
      return base64Decode(stored);
    } on FormatException {
      return null;
    }
  }

  /// Drops the cached chat key for [chatId] (e.g. it failed to decrypt).
  Future<void> clearCachedChatKey(String chatId) async {
    await _storage.delete(key: '$_chatKeyPrefix$chatId');
  }

  /// Wraps [chatKey] for the member whose public key is [memberPubBase64].
  /// Uses an ephemeral X25519 pair so only the recipient can unwrap.
  Future<DictionaryWrap> wrapChatKey({
    required List<int> chatKey,
    required String memberUserId,
    required int deviceKeyVersion,
    required String memberPubBase64,
  }) async {
    final remotePub =
        SimplePublicKey(base64Decode(memberPubBase64), type: KeyPairType.x25519);
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await _sharedWithEphemeral(ephemeral, remotePub);
    final key = await _aesKey(shared);

    final nonce = _randomNonce();
    final box = await _aes.encrypt(
      chatKey,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode('dict-wrap:$memberUserId'),
    );
    return DictionaryWrap(
      userId: memberUserId,
      deviceKeyVersion: deviceKeyVersion,
      encKey: base64Encode(box.cipherText),
      iv: base64Encode(box.nonce),
      authTag: base64Encode(box.mac.bytes),
      wrapPub: base64Encode(ephemeralPub.bytes),
    );
  }

  /// Unwraps [wrap] using this device's keypair. Returns the chat key.
  Future<Uint8List> unwrapChatKey({
    required SimpleKeyPair myKeyPair,
    required DictionaryWrap wrap,
  }) async {
    final ephemeralPub =
        SimplePublicKey(base64Decode(wrap.wrapPub), type: KeyPairType.x25519);
    final shared = await _sharedWithEphemeral(myKeyPair, ephemeralPub);
    final key = await _aesKey(shared);

    final box = SecretBox(
      base64Decode(wrap.encKey),
      nonce: base64Decode(wrap.iv),
      mac: Mac(base64Decode(wrap.authTag)),
    );
    final clear = await _aes.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode('dict-wrap:${wrap.userId}'),
    );
    return Uint8List.fromList(clear);
  }

  // ── Dictionary payload (AES under the chat key) ─────────────────────

  /// Encrypts [entries] into a dictionary blob for a chat.
  Future<({String ciphertext, String iv, String authTag})> encryptEntries({
    required List<DictEntry> entries,
    required List<int> chatKey,
  }) async {
    final key = SecretKeyData(Uint8List.fromList(chatKey));
    final nonce = _randomNonce();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode([for (final e in entries) e.toJson()])),
      secretKey: key,
      nonce: nonce,
    );
    return (
      ciphertext: base64Encode(box.cipherText),
      iv: base64Encode(box.nonce),
      authTag: base64Encode(box.mac.bytes),
    );
  }

  /// Decrypts a dictionary blob back into entries.
  Future<List<DictEntry>> decryptEntries({
    required String ciphertext,
    required String iv,
    required String authTag,
    required List<int> chatKey,
  }) async {
    final key = SecretKeyData(Uint8List.fromList(chatKey));
    final box = SecretBox(
      base64Decode(ciphertext),
      nonce: base64Decode(iv),
      mac: Mac(base64Decode(authTag)),
    );
    final clear = await _aes.decrypt(box, secretKey: key);
    final list = jsonDecode(utf8.decode(clear));
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DictEntry.fromJson)
        .toList();
  }

  // ── Message transforms (pure) ────────────────────────────────────────

  /// Replaces real words with their codes before sending, so only code
  /// words leave the device. Consecutive dictionary words separated only by
  /// whitespace are joined into a `+` stack ("Mark home tomorrow" →
  /// `m+h+t`); punctuation or a non-dictionary word breaks the run.
  /// Multi-word phrase meanings are replaced first (whole-phrase match), so
  /// they keep working alongside stacking. Word-boundary aware; codes pass
  /// through untouched (a code can't be a meaning of another entry).
  static String replaceOutgoing(String text, List<DictEntry> entries) {
    if (entries.isEmpty) return text;
    final valid = [for (final e in entries) if (e.isValid) e];
    if (valid.isEmpty) return text;

    // Phrase meanings (contain whitespace) match as whole phrases first so
    // the single-word stacking pass can't break them apart.
    var result = text;
    for (final e in valid) {
      final meaning = e.meaning.trim();
      if (meaning.contains(' ')) {
        result = _replaceWord(result, meaning, e.code.trim());
      }
    }

    // Single-word meanings, tokenized for stacking.
    final byMeaning = <String, String>{
      for (final e in valid)
        if (!e.meaning.trim().contains(' ')) e.meaning.trim(): e.code.trim(),
    };
    if (byMeaning.isEmpty) return result;

    final out = StringBuffer();
    var flushedTo = 0; // text already emitted up to this offset
    var runCodes = <String>[]; // codes of the current stack run
    var runStart = -1; // offset of the run's first word
    var runEnd = -1; // offset just past the run's last word
    var lastWordEnd = 0;

    void flushRun() {
      if (runCodes.isEmpty) return;
      out.write(result.substring(flushedTo, runStart));
      out.write(runCodes.join('+'));
      flushedTo = runEnd;
      runCodes = [];
      runStart = -1;
    }

    final wordRe = RegExp(r'[\p{L}\p{N}]+', unicode: true);
    final whitespaceOnly = RegExp(r'^\s*$');
    for (final m in wordRe.allMatches(result)) {
      final gap = result.substring(lastWordEnd, m.start);
      final code = byMeaning[m.group(0)!];
      if (code != null && whitespaceOnly.hasMatch(gap)) {
        // Extend the current stack (or start one) — only whitespace between
        // consecutive dictionary words.
        if (runCodes.isEmpty) runStart = m.start;
        runCodes.add(code);
        runEnd = m.end;
      } else {
        flushRun();
        if (code != null) {
          // A dictionary word after punctuation: close any prior run, then
          // start a fresh one here (it can't stack across the punctuation).
          runStart = m.start;
          runCodes.add(code);
          runEnd = m.end;
        }
      }
      lastWordEnd = m.end;
    }
    flushRun();
    out.write(result.substring(flushedTo));
    return out.toString();
  }

  /// Expands code words into their meanings for display. [reveal] selects
  /// which codes to expand; pass the full list to expand everything.
  /// `+`-joined stacks ("m+h+t") expand to space-joined meanings ("Mark home
  /// tomorrow"); each `+`-segment matches the longest known code first and
  /// unknown segments stay literal. Old space-separated codes expand exactly
  /// as before.
  static String expandIncoming(
    String text,
    List<DictEntry> entries, {
    Set<String>? reveal,
  }) {
    if (entries.isEmpty) return text;
    final byCode = <String, String>{};
    for (final e in entries) {
      final code = e.code.trim();
      final meaning = e.meaning.trim();
      if (code.isEmpty || meaning.isEmpty) continue;
      if (reveal != null && !reveal.contains(code)) continue;
      byCode[code] = meaning;
    }
    if (byCode.isEmpty) return text;
    // Longest code first so a prefix code doesn't clobber a longer one.
    final codes = byCode.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    // `+`-stacks first (word-boundary aware): each segment matches the
    // longest known code, meanings are space-joined.
    final runRe = RegExp(
      '(^|[^\\p{L}\\p{N}])'
      '([\\p{L}\\p{N}]+(?:\\+[\\p{L}\\p{N}]+)+)'
      '(\$|[^\\p{L}\\p{N}])',
      unicode: true,
    );
    var result = text.replaceAllMapped(runRe, (m) {
      final expanded = m[2]!
          .split('+')
          .map((segment) => byCode[segment] ?? segment)
          .join(' ');
      return '${m[1]}$expanded${m[3]}';
    });

    // Then standalone codes, longest first (word-boundary aware).
    for (final code in codes) {
      result = _replaceWord(result, code, byCode[code]!);
    }
    return result;
  }

  static String _replaceWord(String text, String from, String to) {
    final escaped = RegExp.escape(from);
    return text.replaceAllMapped(
      RegExp('(^|[^\\p{L}\\p{N}])$escaped(\$|[^\\p{L}\\p{N}])', unicode: true),
      (m) => '${m[1]}$to${m[2]}',
    );
  }

  /// Merges the freshly-fetched [remote] entries with the caller's unsaved
  /// [local] edits after a concurrent save conflict. Local entries win for a
  /// given code; entries the other member added (not present locally) are
  /// preserved. The result keeps the local ordering, appending remote-only
  /// entries, so the loser keeps both users' work.
  static List<DictEntry> mergeDictionaryEntries({
    required List<DictEntry> remote,
    required List<DictEntry> local,
  }) {
    final localCodes = <String>{for (final e in local) e.code};
    return [
      ...local,
      for (final e in remote)
        if (!localCodes.contains(e.code)) e,
    ];
  }

  static Uint8List _randomNonce() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(12, (_) => rng.nextInt(256)));
  }
}