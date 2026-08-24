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

  /// Saves a fully re-encrypted dictionary: the new ciphertext blob plus a
  /// wrap for every current participant. Version must strictly increase.
  Future<int> saveDictionary({
    required String chatId,
    required int version,
    required String ciphertext,
    required String iv,
    required String authTag,
    required List<DictionaryWrap> wraps,
  }) async {
    final data = await _api.put('/chats/$chatId/dictionary', body: {
      'dictionary': {
        'ciphertext': ciphertext,
        'iv': iv,
        'authTag': authTag,
        'version': version,
        'wraps': [for (final w in wraps) w.toJson()],
      },
    });
    final map = data is Map<String, dynamic> ? data : const {};
    return (map['version'] as num?)?.toInt() ?? version;
  }

  /// Registers this device's public key (bumps the user's key version).
  Future<int> registerPublicKey(String encPublicKey) async {
    final data = await _api.post('/user/public-key', body: {
      'encPublicKey': encPublicKey,
    });
    final map = data is Map<String, dynamic> ? data : const {};
    return (map['version'] as num?)?.toInt() ?? 0;
  }

  /// Reads the caller's registered public key + version.
  Future<({String encPublicKey, int version})> getMyPublicKey() async {
    final data = await _api.get('/user/public-key');
    final map = data is Map<String, dynamic> ? data : const {};
    return (
      encPublicKey: map['encPublicKey'] as String? ?? '',
      version: (map['version'] as num?)?.toInt() ?? 0,
    );
  }
}