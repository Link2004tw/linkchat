import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/messages_repository.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

ChatMessage _msg(String id, String content) =>
    ChatMessage(id: id, content: content, contentType: 'text');

void main() {
  group('applyChatEvent with optimistic messages', () {
    test('server echo replaces the optimistic entry by pendingId', () {
      // The controller creates optimistic messages with id == pendingId,
      // and the server echoes the same value back as the real message id.
      const pendingId = 'pending-c1-1';
      final pending = ChatMessage(
        id: pendingId,
        pendingId: pendingId,
        content: 'hello',
        contentType: 'text',
      );
      var state = ChatRoomState(messages: [pending]);

      state = applyChatEvent(
        state,
        WsMessageEvent(message: _msg(pendingId, 'hello')),
      );

      expect(state.messages, hasLength(1));
      expect(state.messages.single.id, pendingId);
      expect(state.messages.single.pendingId, isNull);
      expect(state.messages.single.status, MessageStatus.sent);
    });

    test('failed optimistic message stays after reconnect welcome', () {
      final failed = ChatMessage(
        id: 'pending-c1-1',
        pendingId: 'pending-c1-1',
        content: 'hello',
        contentType: 'text',
        sendFailed: true,
      );
      var state = ChatRoomState(messages: [failed]);

      state = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );

      // Failed messages are kept so the user can retry; pending (unacked)
      // ones are dropped because the replayed history replaces them. The
      // welcome marker itself is not added as a row.
      expect(state.messages, hasLength(1)); // just the failed message
      expect(state.messages.single.sendFailed, isTrue);
    });

    test('pending (unacked) optimistic messages are dropped on welcome', () {
      final pending = ChatMessage(
        id: 'pending-c1-1',
        pendingId: 'pending-c1-1',
        content: 'hello',
        contentType: 'text',
      );
      final state = applyChatEvent(
        ChatRoomState(messages: [pending]),
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );

      // The pending message is dropped (the replayed history replaces it),
      // and the welcome marker is not rendered as a row.
      expect(state.messages, isEmpty);
    });
  });

  group('ChatRoomController.deleteMessageForMe', () {
    test('removes optimistically and confirms via REST', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/c1/messages/m1/delete-for-me');
        return http.Response(
          jsonEncode({'success': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      final container = ProviderContainer(overrides: [
        messagesRepositoryProvider
            .overrideWithValue(MessagesRepository(api)),
      ]);
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.set(ChatRoomState(
        messages: [_msg('m1', 'a'), _msg('m2', 'b')],
      ));

      final ok = await controller.deleteMessageForMe('m1');

      expect(ok, isTrue);
      expect(
        container.read(chatRoomProvider('c1')).messages.map((m) => m.id),
        ['m2'],
      );
    });

    test('restores the message in place when the request fails', () async {
      final mock = MockClient((request) async => http.Response('oops', 500));
      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      final container = ProviderContainer(overrides: [
        messagesRepositoryProvider
            .overrideWithValue(MessagesRepository(api)),
      ]);
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.set(ChatRoomState(
        messages: [_msg('m1', 'a'), _msg('m2', 'b'), _msg('m3', 'c')],
      ));

      final ok = await controller.deleteMessageForMe('m2');

      expect(ok, isFalse);
      expect(
        container.read(chatRoomProvider('c1')).messages.map((m) => m.id),
        ['m1', 'm2', 'm3'], // restored at its original position
      );
    });

    test('returns false for an unknown message id', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.set(ChatRoomState(messages: [_msg('m1', 'a')]));

      final ok = await controller.deleteMessageForMe('nope');

      expect(ok, isFalse);
    });
  });

  group('mergeMessages with optimistic entries', () {
    test('REST pages (older history) keep pending entries', () {
      // Pending ids are client-side and never appear in REST history, so
      // an older page simply prepends and leaves the pending entry alone.
      final pending = ChatMessage(
        id: 'pending-c1-1',
        pendingId: 'pending-c1-1',
        content: 'hello',
        contentType: 'text',
      );
      final merged = mergeMessages(
        [pending],
        [_msg('m9', 'older')],
      );
      expect(merged.map((m) => m.id), ['m9', 'pending-c1-1']);
    });
  });

  group('ChatRoomController.sendText', () {
    test('appends an optimistic message immediately', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      controller.sendText('hello');
      final state = container.read(chatRoomProvider('c1'));
      expect(state.messages, hasLength(1));
      expect(state.messages.single.content, 'hello');
      expect(state.messages.single.pendingId, isNotNull);
    });

    test('marks the message as failed when the socket is down', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      controller.sendText('hello'); // never connected → client is null
      final state = container.read(chatRoomProvider('c1'));
      expect(state.messages.single.sendFailed, isTrue);
      expect(state.messages.single.status, MessageStatus.failed);
    });

    test('ignores empty input', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      controller.sendText('   ');
      expect(container.read(chatRoomProvider('c1')).messages, isEmpty);
    });

    test('retryMessage re-appends the text as a fresh optimistic message', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(chatRoomProvider('c1').notifier);

      controller.sendText('hello');
      final failedId = container.read(chatRoomProvider('c1')).messages.single.id!;

      controller.retryMessage(failedId);
      final state = container.read(chatRoomProvider('c1'));
      expect(state.messages, hasLength(1));
      expect(state.messages.single.content, 'hello');
      expect(state.messages.single.sendFailed, isTrue); // still disconnected
      expect(state.messages.single.id, isNot(failedId)); // new pending id
    });
  });

  group('MessageBubble failed indicator', () {
    testWidgets('shows the retry hint and retries on tap', (tester) async {
      final failed = ChatMessage(
        id: 'pending-c1-1',
        pendingId: 'pending-c1-1',
        content: 'hello',
        contentType: 'text',
        sendFailed: true,
      );
      String? retried;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: failed,
            isMine: true,
            onRetry: (id) => retried = id,
          ),
        ),
      ));

      expect(find.text('Not sent — tap to retry'), findsOneWidget);
      await tester.tap(find.text('hello'));
      expect(retried, 'pending-c1-1');
    });

    testWidgets('no retry hint for sent messages', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: _msg('m1', 'hi'), isMine: true),
        ),
      ));
      expect(find.textContaining('Not sent'), findsNothing);
    });
  });
}
