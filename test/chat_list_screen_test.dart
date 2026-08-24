import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/cache/chat_cache.dart';
import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/screens/chat_list_screen.dart';
import 'package:chat_app/widgets/status_banner.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

Map<String, dynamic> _chat(String id, Map<String, dynamic>? lastMessage) => {
      '_id': id,
      'access': 'direct',
      'unreadCount': 0,
      'updatedAt': '2025-01-01T10:00:00.000Z',
      'lastMessage': lastMessage,
      'otherUser': {
        'clerkId': 'clerk_bob',
        'name': 'Bob',
        'imageUrl': null,
      },
    };

Map<String, dynamic> _groupChat(String id, {String? pictureUrl}) => {
      '_id': id,
      'name': 'Backend Team',
      'access': 'public',
      'pictureUrl': pictureUrl,
      'unreadCount': 0,
      'updatedAt': '2025-01-01T10:00:00.000Z',
      'participantCount': 5,
      'previewMembers': ['alice', 'bob'],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> chatJson) async {
  final mock = MockClient((request) async {
    expect(request.url.path, '/api/chats/all');
    return _json([chatJson]);
  });
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
      chatCacheProvider.overrideWithValue(ChatCache.memory),
    ],
    child: const MaterialApp(home: ChatListScreen()),
  ));
  await tester.pump(); // microtask fetch
  await tester.pump(const Duration(milliseconds: 50)); // REST future
}

/// Pumps the chat list with a fixed connection state (bypasses the real
/// socket entirely).
Future<void> _pumpWithConnection(
  WidgetTester tester,
  ChatListConnection connection,
) async {
  final mock = MockClient((request) async {
    expect(request.url.path, '/api/chats/all');
    return _json([_chat('c1', null)]);
  });
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
      chatCacheProvider.overrideWithValue(ChatCache.memory),
      chatListConnectionProvider.overrideWith(
        () => _FakeConnectionController(connection),
      ),
    ],
    child: const MaterialApp(home: ChatListScreen()),
  ));
  await tester.pump(); // microtask fetch
  await tester.pump(const Duration(milliseconds: 50)); // REST future
}

class _FakeConnectionController extends ChatListConnectionController {
  _FakeConnectionController(this.connection);

  final ChatListConnection connection;

  @override
  ChatListConnection build() => connection;
}

void main() {
  testWidgets('image last-message shows a thumbnail next to the preview',
      (tester) async {
    await _pump(tester, _chat('c1', {
      'content': '📷 Photo',
      'contentType': 'image',
      'mediaUrl': 'https://res.cloudinary.com/x/image.jpg',
      'sentAt': '2025-01-01T09:59:00.000Z',
      'senderId': 'bob',
    }));

    expect(find.text('Bob'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('📷 Photo'), findsOneWidget);
  });

  testWidgets('image with a caption shows the caption and the thumbnail',
      (tester) async {
    await _pump(tester, _chat('c1', {
      'content': 'sunset over the bay',
      'contentType': 'image',
      'mediaUrl': 'https://res.cloudinary.com/x/image.jpg',
      'sentAt': '2025-01-01T09:59:00.000Z',
      'senderId': 'bob',
    }));

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('sunset over the bay'), findsOneWidget);
  });

  testWidgets('text last-message shows no thumbnail', (tester) async {
    await _pump(tester, _chat('c1', {
      'content': 'hello',
      'contentType': 'text',
      'sentAt': '2025-01-01T09:59:00.000Z',
      'senderId': 'bob',
    }));

    expect(find.textContaining('hello'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('group room with a picture shows it as the avatar',
      (tester) async {
    await _pump(tester, _groupChat('g1', pictureUrl: 'https://img/room.png'));

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.foregroundImage, isA<NetworkImage>());
    expect(find.text('B'), findsNothing);

    // The test environment stubs all HTTP with 400s, so the NetworkImage
    // fails to decode — swallow the expected image-load error.
    tester.takeException();
  });

  testWidgets('group room without a picture falls back to the initial',
      (tester) async {
    await _pump(tester, _groupChat('g2'));

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.foregroundImage, isNull);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('no banner while the socket is healthy', (tester) async {
    await _pumpWithConnection(tester, (
      isConnected: true,
      attempts: 0,
      lastError: null,
    ));

    expect(find.textContaining('Connection lost'), findsNothing);
  });

  testWidgets('banner shows the failure detail when the last drop errored',
      (tester) async {
    await _pumpWithConnection(tester, (
      isConnected: false,
      attempts: 1,
      lastError: (
        url: 'ws://localhost:47154/ws/chat-list',
        message: 'Connection refused',
      ),
    ));

    expect(find.textContaining('Connection lost'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsOneWidget);
    expect(find.textContaining('ws://localhost:47154'), findsOneWidget);
  });

  testWidgets('banner falls back to generic text after a clean close',
      (tester) async {
    await _pumpWithConnection(tester, (
      isConnected: false,
      attempts: 2,
      lastError: null,
    ));

    expect(find.text('Connection lost — reconnecting…'), findsOneWidget);
  });

  testWidgets('tapping the banner copies the error to the clipboard',
      (tester) async {
    await _pumpWithConnection(tester, (
      isConnected: false,
      attempts: 1,
      lastError: (
        url: 'ws://localhost:47154/ws/chat-list',
        message: 'Connection refused',
      ),
    ));

    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.tap(find.byType(StatusBanner));
    await tester.pump();

    final setData = calls.where((c) => c.method == 'Clipboard.setData');
    expect(setData, hasLength(1));
    final args = setData.first.arguments as Map<Object?, Object?>;
    expect(
      (args['text'] as String),
      contains('Connection refused (ws://localhost:47154/ws/chat-list)'),
    );
    // Confirmation snackbar appears.
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });
}
