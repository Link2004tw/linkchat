import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/save_image.dart';
import '../utils/snack.dart';

/// Full-screen, zoomable image viewer for media messages, with a
/// save-to-gallery action.
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.url});

  final String url;

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await saveImageToGallery(url);
    showSnackVia(messenger, error ?? 'Image saved to gallery');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Save image',
            onPressed: () => _save(context),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: url,
            placeholder: (_, _) => const CircularProgressIndicator(),
            errorWidget: (_, _, _) => const Icon(
              Icons.broken_image,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
