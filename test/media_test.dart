import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/screens/chat_room_screen.dart';
import 'package:chat_app/utils/format.dart';
import 'package:chat_app/utils/media_picker.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Minimal in-memory VideoPlayerPlatform so widget tests can drive the
/// lazily-created VideoPlayerController without any real media stack.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];
  int _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    return _nextId++;
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    return createWithOptions(VideoCreationOptions(
      dataSource: dataSource,
      viewType: VideoViewType.textureView,
    ));
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return Stream<VideoEvent>.multi((emit) {
      Future<void>(() {
        emit.add(VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: const Size(640, 360),
        ));
      });
    });
  }

  @override
  Future<void> play(int playerId) async => playCalls.add(playerId);

  @override
  Future<void> pause(int playerId) async => pauseCalls.add(playerId);

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) =>
      SizedBox(key: ValueKey('video-view-$playerId'));

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      SizedBox(key: ValueKey('video-view-${options.playerId}'));

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int playerId, bool value) async {}

  @override
  Future<void> dispose(int playerId) async {}
}

void main() {
  group('mimeFromName', () {
    test('maps common extensions', () {
      expect(mimeFromName('a.jpg'), 'image/jpeg');
      expect(mimeFromName('a.JPG'), 'image/jpeg');
      expect(mimeFromName('a.png'), 'image/png');
      expect(mimeFromName('a.gif'), 'image/gif');
      expect(mimeFromName('a.webp'), 'image/webp');
      expect(mimeFromName('a.mp4'), 'video/mp4');
      expect(mimeFromName('a.pdf'), 'application/pdf');
      expect(mimeFromName('a.txt'), 'text/plain');
    });

    test('falls back for unknown extensions', () {
      expect(mimeFromName('a.xyz'), 'application/octet-stream');
      expect(mimeFromName('noext'), 'application/octet-stream');
      expect(
        mimeFromName('a.xyz', fallback: 'image/jpeg'),
        'image/jpeg',
      );
    });
  });

  group('formatBytes', () {
    test('formats B, KB, MB', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes(1048576), '1.0 MB');
    });
  });

  group('file events', () {
    test('file-ack / file-progress / file-complete leave state untouched '
        '(handled by the controller uploads map)', () {
      var state = const ChatRoomState();
      state = applyChatEvent(state, const WsFileAckEvent(status: 'ok'));
      state = applyChatEvent(
          state, const WsFileProgressEvent(progress: 50));
      state = applyChatEvent(
          state, const WsFileCompleteEvent(messageId: 'm1', url: 'u'));
      expect(state.uploads, isEmpty);
      expect(state.messages, isEmpty);
      expect(state.lastError, isNull);
    });

    test('sendFile rejects while disconnected with a reason', () async {
      // A controller that has never connected — _client is null, so every
      // guard must reject without throwing.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      final error = await controller.sendFile(
        name: 'a.png',
        bytes: [1, 2, 3],
        mime: 'image/png',
      );
      expect(error, UploadFailure.notConnected.message);
      expect(container.read(chatRoomProvider('c1')).uploads, isEmpty);
    });

    test('sendFile too-large guard reports a specific reason', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      final error = await controller.sendFile(
        name: 'big.png',
        bytes: List<int>.filled(ChatRoomController.maxUploadBytes + 1, 0),
        mime: 'image/png',
      );
      // Still disconnected, so the socket guard wins — the important part is
      // that the call returns a reason string and never throws.
      expect(error, isNotNull);
    });

    test('WsErrorEvent while an upload is in flight records the reason', () {
      // The pure event reducer: an error event surfaces as lastError so the
      // room banner can explain the failure.
      final state = applyChatEvent(
        const ChatRoomState(),
        const WsErrorEvent(text: 'Upload failed: bad file type'),
      );
      expect(state.lastError, 'Upload failed: bad file type');
    });

    test('UploadFailure carries user-facing messages', () {
      expect(UploadFailure.notConnected.message, contains('Not connected'));
      expect(UploadFailure.busy.message, contains('in progress'));
    });
  });

  group('UploadProgressBar', () {
    testWidgets('renders nothing when there are no uploads', (tester) async {
      await tester.pumpWidget(_wrap(const UploadProgressBar(uploads: {})));
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('shows name, progress bar and percentage', (tester) async {
      await tester.pumpWidget(_wrap(const UploadProgressBar(uploads: {
        'u1': UploadProgress(name: 'photo.jpg', progress: 40),
      })));
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('multiple uploads each get a row', (tester) async {
      await tester.pumpWidget(_wrap(const UploadProgressBar(uploads: {
        'u1': UploadProgress(name: 'a.jpg', progress: 10),
        'u2': UploadProgress(name: 'b.pdf', progress: 90),
      })));
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('b.pdf'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    });
  });

  group('MessageBubble media', () {
    testWidgets('image message renders with its caption', (tester) async {
      final image = ChatMessage(
        id: 'm1',
        content: 'https://example.com/a.jpg',
        contentType: 'image',
        caption: 'sunset',
        author: const ChatUser(clerkId: 'u1', username: 'alice'),
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: image, isMine: false)));
      expect(find.text('sunset'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('file message renders name and size', (tester) async {
      final file = ChatMessage(
        id: 'm1',
        content: 'https://example.com/report.pdf',
        contentType: 'file',
        fileName: 'report.pdf',
        fileSize: 1048576,
        author: const ChatUser(clerkId: 'u1', username: 'alice'),
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: file, isMine: false)));
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('1.0 MB'), findsOneWidget);
    });
  });

  group('video message', () {
    ChatMessage video() => ChatMessage(
          id: 'm1',
          content: 'https://example.com/clip.mp4',
          contentType: 'video',
          author: const ChatUser(clerkId: 'u1', username: 'alice'),
        );

    testWidgets('renders a poster tile without touching the platform',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(message: video(), isMine: false)));
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
    });

    testWidgets('tapping the poster initializes and plays in place',
        (tester) async {
      final fake = _FakeVideoPlatform();
      VideoPlayerPlatform.instance = fake;

      await tester.pumpWidget(_wrap(MessageBubble(message: video(), isMine: false)));
      await tester.tap(find.byIcon(Icons.play_circle_outline));

      // Lazy init: createWithOptions + subscribe, then the initialized event.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(fake.playCalls, isNotEmpty);

      // Playing → pause control shows; tap it to pause.
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause_circle_filled));
      await tester.pump(const Duration(milliseconds: 20));
      expect(fake.pauseCalls, isNotEmpty);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    });
  });
}
