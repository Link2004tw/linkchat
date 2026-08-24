import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../../models/message.dart';
import '../../screens/image_viewer_screen.dart';
import '../../utils/format.dart';
import '../../utils/snack.dart';
import 'link_launcher.dart';

// The per-content-type bubbles: image, video, file, voice note. Extracted
// from message_bubble.dart so each media kind owns its own player/lifecycle;
// MessageBubble's [_Content] picks one based on `contentType`.

class ImageMessage extends StatelessWidget {
  const ImageMessage({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ImageViewerScreen(url: url)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: url,
          width: 220,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: 220,
            height: 140,
            color: Colors.black12,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (_, _, _) => Container(
            width: 220,
            height: 140,
            color: Colors.black12,
            child: const Center(child: Icon(Icons.broken_image)),
          ),
        ),
      ),
    );
  }
}

/// Inline video player. Renders a poster tile until tapped; the player is
/// created lazily on the first tap so rendering a video message never touches
/// the network. After initialize the video plays in place (letterboxed) with
/// a minimal play/pause + progress control mirroring the audio bubble.
class VideoMessage extends StatefulWidget {
  const VideoMessage({super.key, required this.url});

  final String url;

  @override
  State<VideoMessage> createState() => _VideoMessageState();
}

class _VideoMessageState extends State<VideoMessage> {
  VideoPlayerController? _controller;
  bool _initializing = false;
  bool _failed = false;

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) {
      if (_failed) {
        openUrl(context, widget.url);
        return;
      }
      if (_initializing) return;
      setState(() => _initializing = true);
      try {
        final created =
            VideoPlayerController.networkUrl(Uri.parse(widget.url));
        await created.initialize();
        if (!mounted) {
          created.dispose();
          return;
        }
        setState(() {
          _controller = created;
          _initializing = false;
        });
        await created.play();
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _failed = true;
        });
      }
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
      return;
    }
    final v = controller.value;
    if (v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final durationMs = value.duration.inMilliseconds;
              final progress = durationMs > 0
                  ? (value.position.inMilliseconds / durationMs).clamp(0.0, 1.0)
                  : 0.0;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                    ),
                    color: theme.colorScheme.primary,
                    onPressed: _togglePlay,
                  ),
                  SizedBox(
                    width: 130,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          durationMs > 0
                              ? '${formatDuration(value.position)} / ${formatDuration(value.duration)}'
                              : 'Video',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      );
    }
    return GestureDetector(
      onTap: _togglePlay,
      child: Container(
        width: 220,
        height: 130,
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: _initializing
            ? const Center(child: CircularProgressIndicator())
            : Icon(
                _failed ? Icons.open_in_new : Icons.play_circle_outline,
                size: 48,
                color: theme.colorScheme.primary,
              ),
      ),
    );
  }
}

class FileMessage extends StatelessWidget {
  const FileMessage({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileName = message.fileName ?? 'File';
    final size = message.fileSize;

    return GestureDetector(
      onTap: () => openUrl(context, message.content),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (size != null)
                  Text(
                    formatBytes(size),
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Voice note bubble: play/pause toggle with a live progress bar and a
/// position/duration readout. One [AudioPlayer] per bubble, disposed with
/// the widget.
class AudioMessage extends StatefulWidget {
  const AudioMessage({super.key, required this.url, this.isMine = false});

  final String url;
  final bool isMine;

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _localPath;

  Future<void> _ensureLocal() async {
    if (_localPath != null) return;
    final uri = Uri.parse(widget.url);
    final resp = await http.get(uri);
    final tmp = File('${Directory.systemTemp.path}/voice_${uri.pathSegments.last}');
    await tmp.writeAsBytes(resp.bodyBytes);
    _localPath = tmp.path;
  }

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    if (_localPath != null) {
      try { File(_localPath!).deleteSync(); } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    try {
      await _ensureLocal();
      await _player.setVolume(1.0);
      await _player.play(DeviceFileSource(_localPath!));
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        showSnack(context, 'Could not play audio');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = _duration.inMilliseconds;
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _playing
                ? Icons.pause_circle_filled
                : Icons.play_circle_fill,
          ),
          color: widget.isMine ? Colors.white : theme.colorScheme.primary,
          onPressed: _toggle,
        ),
        SizedBox(
          width: 140,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 4),
              Text(
                totalMs > 0
                    ? '${formatDuration(_position)} / ${formatDuration(_duration)}'
                    : 'Voice message',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: widget.isMine ? Colors.white70 : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
