import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key-value seam over [FlutterSecureStorage] so tests can
/// substitute an in-memory implementation without touching platform
/// channels (the plugin's own API takes many option parameters).
abstract class SecureKeyValue {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SecureKeyValueStorage implements SecureKeyValue {
  const SecureKeyValueStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Provides the AES-256 key that encrypts the on-disk Hive cache.
///
/// The cache holds decrypted dictionaries, messages and the chat list —
/// everything E2E protects in transit. The key is generated once and kept
/// in secure storage (same trust level as the dictionary device seed), so
/// app files alone reveal nothing.
///
/// When secure storage isn't available, [ensureKey] returns null and the
/// caller must fall back to a non-persistent (in-memory) cache — we never
/// write sensitive data to disk in plaintext.
class CacheEncryption {
  CacheEncryption({SecureKeyValue? storage})
      : _storage = storage ?? const SecureKeyValueStorage();

  static const String _keyStorageKey = 'cache_hive_key';

  final SecureKeyValue _storage;

  /// Returns the 32-byte cache encryption key, creating it on first call.
  /// A corrupt/unusable stored value is replaced with a fresh key (the old
  /// encrypted cache is disposable). Returns null only when secure storage
  /// itself is unavailable — the caller then degrades to an in-memory
  /// cache instead of writing plaintext to disk.
  Future<Uint8List?> ensureKey() async {
    try {
      final existing = await _storage.read(_keyStorageKey);
      if (existing != null && existing.isNotEmpty) {
        final key = _tryDecode(existing);
        if (key != null && key.length == 32) return key;
      }
      final fresh = _generate();
      await _storage.write(_keyStorageKey, base64Encode(fresh));
      return fresh;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _tryDecode(String value) {
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  static Uint8List _generate() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }
}
