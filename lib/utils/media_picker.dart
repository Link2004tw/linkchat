import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

/// A picked file ready to send over the chat WebSocket.
class PickedMedia {
  const PickedMedia({required this.bytes, required this.name, required this.mime});

  final List<int> bytes;
  final String name;
  final String mime;
}

enum MediaSource { photo, file }

/// Picks an image from the gallery (resized/compressed a bit) and reads its
/// bytes. Returns null when the user cancels.
Future<PickedMedia?> pickImage() async {
  final image = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1920,
    imageQuality: 85,
  );
  if (image == null) return null;
  final bytes = await image.readAsBytes();
  return PickedMedia(
    bytes: bytes,
    name: image.name,
    mime: mimeFromName(image.name, fallback: 'image/jpeg'),
  );
}

/// Picks any file and reads its bytes (kept in memory — 6 MB cap applies
/// before sending). Returns null when the user cancels.
Future<PickedMedia?> pickFile() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return PickedMedia(
    bytes: bytes,
    name: file.name,
    mime: mimeFromName(file.name),
  );
}

/// Minimal extension → MIME map. The backend only distinguishes
/// image/* (→ image), video/* (→ video) and everything else (→ file).
String mimeFromName(String name, {String fallback = 'application/octet-stream'}) {
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' || 'heif' => 'image/heic',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'zip' => 'application/zip',
    _ => fallback,
  };
}
