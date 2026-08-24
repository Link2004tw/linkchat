import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/messages_repository.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

ChatMessage _msg(String id, String content) =>
    ChatMessage(id: id, content: content, contentType: 'text');

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

void main() {
  group('mergeMessages', () {
    test('prepends an older page before the existing messages', () {
      final merged = mergeMessages(
        [_msg('m3', 'newest'), _msg('m2', 'middle')],
        [_msg('m5', 'oldest'), _msg('m4', 'older')],
      );
      expect(merged.map((m) => m.id), ['m5', 'm4', 'm3', 'm2']);
    });

    test('deduplicates ids that overlap with existing messages', () {
      final merged = mergeMessages(
        [_msg('m3', 'newest'), _msg('m2', 'middle')],
        [_msg('m3', 'dupe'), _msg('m4', 'older')],
      );
      expect(merged.map((m) => m.id), ['m4', 'm3', 'm2']);
      expect(merged.first.content, 'older');
      // The existing m3 content wins (page entries are dropped, not merged).
      expect(merged[1].content, 'newest');
    });

    test('returns existing when the page is empty', () {
      final existing = [_msg('m1', 'a')];
      expect(mergeMessages(existing, const []), same(existing));
    });

    test('keeps messages without ids from the page', () {
      final merged = mergeMessages(
        [_msg('m1', 'a')],
        [ChatMessage(id: null, content: 'no-id', contentType: 'text')],
      );
      expect(merged, hasLength(2));
    });
  });

  group('ChatRoomController.loadOlderMessages', () {
    test('fetches with the initial cursor and prepends the page', () async {
      final requested = <String>[];
      final mock = MockClient((request) async {
        requested.add('${request.method} ${request.url.path}?${request.url.query}');
        expect(request.url.path, '/api/chats/c1/messages');
        return _json({
          'messages': [
            {
              '_id': 'm5',
              'content': 'oldest',
              'contentType': 'text',
              'createdAt': '2025-01-01T10:00:00.000Z',
            },
            {
              '_id': 'm4',
              'content': 'older',
              'contentType': 'text',
              'createdAt': '2025-01-02T10:00:00.000Z',
            },
          ],
          'name': 'room',
          'more': false,
          'nextCursor': null,
        });
      });

      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      final container = ProviderContainer(
        overrides: [
          messagesRepositoryProvider.overrideWithValue(MessagesRepository(api)),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(chatRoomProvider('c1').notifier);
      // Simulate WS history already loaded (chronological: oldest first).
      controller.state = controller.state.copyWith(
        messages: [_msg('m3', 'oldest-so-far'), _msg('m2', 'newest')],
        hasMoreHistory: true,
      );

      await controller.loadOlderMessages();

      // Request carried the oldest message id as the before cursor.
      expect(requested, hasLength(1));
      expect(requested.single, contains('before=m3'));

      final state = container.read(chatRoomProvider('c1'));
      expect(state.messages.map((m) => m.id), ['m5', 'm4', 'm3', 'm2']);
      expect(state.hasMoreHistory, isFalse);
      expect(state.isLoadingMore, isFalse);
      expect(state.loadMoreError, isNull);
    });

    test('no-ops while already loading or when history is exhausted',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        return _json({'messages': <Object>[], 'more': false, 'nextCursor': null});
      });
      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      final container = ProviderContainer(
        overrides: [
          messagesRepositoryProvider.overrideWithValue(MessagesRepository(api)),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.state = controller.state.copyWith(
        messages: [_msg('m1', 'a')],
        hasMoreHistory: false,
      );

      await controller.loadOlderMessages();
      expect(calls, 0);

      controller.state = controller.state.copyWith(
        hasMoreHistory: true,
        isLoadingMore: true,
      );
      await controller.loadOlderMessages();
      expect(calls, 0);
    });

    test('records the error when the fetch fails', () async {
      final mock = MockClient(
        (request) async => http.Response('oops', 500, headers: _jsonHeaders),
      );
      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      final container = ProviderContainer(
        overrides: [
          messagesRepositoryProvider.overrideWithValue(MessagesRepository(api)),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.state = controller.state.copyWith(messages: [_msg('m2', 'a')]);

      await controller.loadOlderMessages();

      final state = container.read(chatRoomProvider('c1'));
      expect(state.isLoadingMore, isFalse);
      expect(state.loadMoreError, isNotNull);
      expect(state.hasMoreHistory, isTrue);
    });
  });

  group('MessageList load-older row', () {
    testWidgets('shows the button at the top when more history exists',
        (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        hasMoreHistory: true,
        messages: [_msg('m2', 'older'), _msg('m1', 'newest')],
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageList(state: state, me: null, onLoadOlder: () async {}),
        ),
      ));
      expect(find.text('Load older messages'), findsOneWidget);
    });

    testWidgets('hides the button when there is no more history',
        (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        hasMoreHistory: false,
        messages: [_msg('m1', 'a')],
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageList(state: state, me: null)),
      ));
      expect(find.text('Load older messages'), findsNothing);
    });

    testWidgets('shows a spinner while loading older messages',
        (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        hasMoreHistory: true,
        isLoadingMore: true,
        messages: [_msg('m1', 'a')],
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageList(state: state, me: null, onLoadOlder: () async {}),
        ),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Load older messages'), findsNothing);
    });

    testWidgets('shows the error with a retry', (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        hasMoreHistory: true,
        loadMoreError: 'Could not load older messages (500)',
        messages: [_msg('m1', 'a')],
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageList(state: state, me: null, onLoadOlder: () async {}),
        ),
      ));
      expect(find.textContaining('Could not load older messages'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });
  });
}
