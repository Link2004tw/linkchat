/// Wire values for message / chat-list `contentType` fields.
///
/// Single source of truth so adding a media kind means changing one
/// constant instead of hunting string literals across screens — and a
/// typo fails to compile instead of silently comparing false.
abstract final class ContentTypes {
  static const text = 'text';
  static const image = 'image';
  static const video = 'video';
  static const file = 'file';
  static const audio = 'audio';
  static const system = 'system';
}

/// True when [contentType] is one of the media types (anything carrying a
/// URL rather than plain text). Null (legacy payloads) is not media.
bool isMediaContentType(String? contentType) =>
    contentType == ContentTypes.image ||
    contentType == ContentTypes.video ||
    contentType == ContentTypes.audio ||
    contentType == ContentTypes.file;
