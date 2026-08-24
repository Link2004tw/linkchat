import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;

/// Fetches [url] and saves it to the device gallery (via `gal`).
///
/// Returns an error message on failure, or null on success so callers can
/// show the right snackbar. Web uses [Gal.putImageBytes]; other platforms
/// write a temp file (requesting gallery access first on iOS) and import it.
Future<String?> saveImageToGallery(String url) async {
  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return 'Could not download image';
    final bytes = response.bodyBytes;
    final stamp = DateTime.now().millisecondsSinceEpoch;

    if (kIsWeb) {
      await Gal.putImageBytes(bytes, name: 'chat_image_$stamp');
      return null;
    }

    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) return 'Gallery permission denied';
    }
    final file = File(
      '${Directory.systemTemp.path}/chat_image_$stamp.jpg',
    );
    await file.writeAsBytes(bytes);
    await Gal.putImage(file.path);
    return null;
  } on Exception {
    return 'Could not save image';
  }
}
