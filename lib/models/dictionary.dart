import 'json_utils.dart';

/// One code-word entry of a chat's private dictionary.
///
/// [code] is the short opaque token stored in messages (e.g. `m`); [meaning]
/// is the real word/phrase it stands for (e.g. `Mark`), which only exists in
/// the decrypted dictionary — never in message content.
class DictEntry {
  const DictEntry({required this.code, required this.meaning});

  final String code;
  final String meaning;

  bool get isValid => code.trim().isNotEmpty && meaning.trim().isNotEmpty;

  DictEntry copyWith({String? code, String? meaning}) => DictEntry(
        code: (code ?? this.code).trim(),
        meaning: (meaning ?? this.meaning).trim(),
      );

  factory DictEntry.fromJson(Map<String, dynamic> json) => DictEntry(
        code: asString(json['code']) ?? '',
        meaning: asString(json['meaning']) ?? '',
      );

  Map<String, dynamic> toJson() => {'code': code, 'meaning': meaning};

  @override
  String toString() => '$code → $meaning';
}

/// The raw encrypted dictionary + everything needed to (re)wrap the shared
/// chat key. Entries are produced by decrypting with the chat key.
class DictionaryContext {
  const DictionaryContext({
    this.ciphertext,
    this.iv,
    this.authTag,
    required this.version,
    required this.wraps,
    required this.participants,
  });

  /// Null when the chat has no dictionary yet (lazy init on first use).
  final String? ciphertext;
  final String? iv;
  final String? authTag;
  final int version;

  /// userId → wrap (opaque, for unwrapping the chat key).
  final Map<String, DictionaryWrap> wraps;

  /// Chat participants with their public keys (for wrapping).
  final List<DictionaryMember> participants;

  bool get exists => ciphertext != null;

  factory DictionaryContext.fromJson(Map<String, dynamic> json) {
    final dictionary = json['dictionary'];
    final dictionaryMap = dictionary is Map<String, dynamic> ? dictionary : null;
    final participants = json['participants'] is List
        ? (json['participants'] as List)
            .whereType<Map<String, dynamic>>()
            .map(DictionaryMember.fromJson)
            .toList()
        : const <DictionaryMember>[];
    final rawWraps = dictionaryMap != null &&
            dictionaryMap['wraps'] is List
        ? (dictionaryMap['wraps'] as List)
            .whereType<Map<String, dynamic>>()
            .map(DictionaryWrap.fromJson)
            .toList()
        : const <DictionaryWrap>[];

    return DictionaryContext(
      ciphertext: asString(dictionaryMap?['ciphertext']),
      iv: asString(dictionaryMap?['iv']),
      authTag: asString(dictionaryMap?['authTag']),
      version: asInt(dictionaryMap?['version']) ?? 0,
      wraps: {for (final w in rawWraps) w.userId: w},
      participants: participants,
    );
  }

  DictionaryMember? memberByClerkId(String clerkId) {
    for (final p in participants) {
      if (p.clerkId == clerkId) return p;
    }
    return null;
  }
}

/// A chat participant as returned with the dictionary context.
class DictionaryMember {
  const DictionaryMember({
    required this.userId,
    required this.clerkId,
    required this.username,
    required this.encPublicKey,
    required this.encPublicKeyVersion,
  });

  final String userId;
  final String clerkId;
  final String username;

  /// Base64 X25519 public key, or empty if the member never registered.
  final String encPublicKey;
  final int encPublicKeyVersion;

  bool get hasPublicKey => encPublicKey.isNotEmpty;

  factory DictionaryMember.fromJson(Map<String, dynamic> json) =>
      DictionaryMember(
        userId: asString(json['userId']) ?? '',
        clerkId: asString(json['clerkId']) ?? '',
        username: asString(json['username']) ?? '',
        encPublicKey: asString(json['encPublicKey']) ?? '',
        encPublicKeyVersion: asInt(json['encPublicKeyVersion']) ?? 0,
      );
}

/// A wrapped copy of the shared chat key for one member.
class DictionaryWrap {
  const DictionaryWrap({
    required this.userId,
    required this.deviceKeyVersion,
    required this.encKey,
    required this.iv,
    required this.authTag,
    required this.wrapPub,
  });

  final String userId;
  final int deviceKeyVersion;
  final String encKey;
  final String iv;
  final String authTag;

  /// Ephemeral X25519 public key used to seal this wrap.
  final String wrapPub;

  factory DictionaryWrap.fromJson(Map<String, dynamic> json) => DictionaryWrap(
        userId: asString(json['userId']) ?? '',
        deviceKeyVersion: asInt(json['deviceKeyVersion']) ?? 0,
        encKey: asString(json['encKey']) ?? '',
        iv: asString(json['iv']) ?? '',
        authTag: asString(json['authTag']) ?? '',
        wrapPub: asString(json['wrapPub']) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'deviceKeyVersion': deviceKeyVersion,
        'encKey': encKey,
        'iv': iv,
        'authTag': authTag,
        'wrapPub': wrapPub,
      };
}