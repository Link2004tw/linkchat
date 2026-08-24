import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/services/cache_encryption.dart';

/// In-memory stand-in for secure storage (no platform channels in tests).
class _MemStorage implements SecureKeyValue {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// Simulates secure storage being unavailable (keystore/locksmith missing).
class _BrokenStorage implements SecureKeyValue {
  @override
  Future<String?> read(String key) async =>
      throw Exception('secure storage unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('secure storage unavailable');
}

void main() {
  group('CacheEncryption.ensureKey', () {
    test('generates a 32-byte key and persists it', () async {
      final storage = _MemStorage();
      final key = await CacheEncryption(storage: storage).ensureKey();

      expect(key, isNotNull);
      expect(key!.length, 32);
      expect(storage.data['cache_hive_key'], isNotEmpty);
    });

    test('returns the same key on subsequent calls', () async {
      final encryption = CacheEncryption(storage: _MemStorage());
      final first = await encryption.ensureKey();
      final second = await encryption.ensureKey();

      expect(List<int>.from(second!), equals(List<int>.from(first!)));
    });

    test('adopts a previously persisted key', () async {
      final storage = _MemStorage()
        ..data['cache_hive_key'] =
            base64Encode(Uint8List.fromList(List.filled(32, 7)));
      final key = await CacheEncryption(storage: storage).ensureKey();

      expect(key, everyElement(7));
    });

    test('regenerates when the stored value is corrupt base64', () async {
      final storage = _MemStorage()..data['cache_hive_key'] = '!!!not-b64!!!';
      final key = await CacheEncryption(storage: storage).ensureKey();

      expect(key, isNotNull);
      expect(key!.length, 32);
      expect(storage.data['cache_hive_key'], isNot('!!!not-b64!!!'));
    });

    test('regenerates when the stored key has the wrong length', () async {
      final storage = _MemStorage()..data['cache_hive_key'] = base64Encode([
        for (var i = 0; i < 8; i++) 1,
      ]);
      final key = await CacheEncryption(storage: storage).ensureKey();

      expect(key, isNotNull);
      expect(key!.length, 32);
    });

    test('returns null (never throws) when secure storage is unavailable',
        () async {
      final key = await CacheEncryption(storage: _BrokenStorage()).ensureKey();
      expect(key, isNull);
    });
  });
}
