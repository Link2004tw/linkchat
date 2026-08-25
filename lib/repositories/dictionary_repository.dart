import '../core/api_client.dart';
import '../models/dictionary.dart';

/// REST access to the encrypted dictionary endpoints.
///
/// - `GET /chats/:chatId/dictionary` → encrypted blob + wraps + participants
/// - `PUT /chats/:chatId/dictionary` → save a new blob + full wrap set
/// - `GET|POST /user/public-key` → register/read this device's public key
///
/// All payloads are opaque to the backend (E2E); this client only moves
/// bytes around.
class DictionaryRepository {
  DictionaryRepository(this._api);

  final ApiClient _api;

  Future<DictionaryContext> getDictionary(String chatId) async {
    final data = await _api.get('/chats/$chatId/dictionary');
    return DictionaryContext.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// Saves a fully re-encrypted dictionary. Legacy payloads carry a wrap
  /// for every current participant; locked ("locked-v1") payloads pass
  /// [lock] instead and omit wraps. Version must strictly increase.
  Future<int> saveDictionary({
    required String chatId,
    required int version,
    required String ciphertext,
    required String iv,
    required String authTag,
    List<DictionaryWrap> wraps = const [],
    DictionaryLockMeta? lock,
  }) async {
    final dictionary = lock != null
        ? {
            'ciphertext': ciphertext,
            'iv': iv,
            'authTag': authTag,
            'version': version,
            'format': 'locked-v1',
            'kdf': lock.toJson(),
          }
        : {
            'ciphertext': ciphertext,
            'iv': iv,
            'authTag': authTag,
            'version': version,
            'wraps': [for (final w in wraps) w.toJson()],
          };
    final data = await _api.put('/chats/$chatId/dictionary', body: {
      'dictionary': dictionary,
    });
    final map = data is Map<String, dynamic> ? data : const {};
    return (map['version'] as num?)?.toInt() ?? version;
  }

  /// Registers this device's public key under [deviceId] (bumps that
  /// device's key version; other devices are unaffected).
  Future<int> registerPublicKey(String encPublicKey, String deviceId) async {
    final data = await _api.post('/user/public-key', body: {
      'encPublicKey': encPublicKey,
      'deviceId': deviceId,
    });
    final map = data is Map<String, dynamic> ? data : const {};
    return (map['version'] as num?)?.toInt() ?? 0;
  }

  /// Reads the caller's registered devices (deviceId + public key + version).
  Future<List<DictionaryMember>> getMyDevices() async {
    final data = await _api.get('/user/public-key');
    final map = data is Map<String, dynamic> ? data : const {};
    final raw = map['devices'];
    if (raw is! List) {
      // Legacy backend shape: a single flat key.
      final pub = map['encPublicKey'] as String? ?? '';
      final version = (map['version'] as num?)?.toInt() ?? 0;
      if (pub.isEmpty) return const [];
      return [
        DictionaryMember(
          userId: '',
          clerkId: '',
          username: '',
          deviceId: 'default',
          encPublicKey: pub,
          encPublicKeyVersion: version,
        ),
      ];
    }
    return [
      for (final d in raw)
        if (d is Map<String, dynamic>)
          DictionaryMember(
            userId: '',
            clerkId: '',
            username: '',
            deviceId: d['deviceId'] as String? ?? 'default',
            encPublicKey: d['encPublicKey'] as String? ?? '',
            encPublicKeyVersion: (d['version'] as num?)?.toInt() ?? 0,
          ),
    ];
  }
}