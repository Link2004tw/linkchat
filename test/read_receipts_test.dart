import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/ws_client.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';

ChatMessage _own(
  String id,
  String content,
  DateTime createdAt, {
  List<SeenByUser> seenBy = const [],
}) =>
    ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: ChatUser(clerkId: 'me', username: 'me'),
      createdAt: createdAt,
      seenBy: seenBy,
    );

ChatMessage _other(String id, String content, DateTime createdAt) =>
    ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: ChatUser(clerkId: 'alice', username: 'alice'),
      createdAt: createdAt,
    );

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 10);
  final t1 = DateTime.utc(2026, 1, 1, 11);
  final t2 = DateTime.utc(2026, 1, 1, 12);

  group('seenBy model parsing', () {
    test('ChatMessage.fromRest parses seenBy', () {
      final msg = ChatMessage.fromRest({
        '_id': 'm1',
        'content': 'hi',
        'contentType': 'text',
        'seenBy': [
          {'userId': 'bob', 'username': 'bob', 'lastReadAt': t1.toIso8601String()},
          {'userId': 'carol', 'username': 'carol'},
        ],
      });
      expect(msg.seenBy, hasLength(2));
      expect(msg.seenBy.first.userId, 'bob');
      expect(msg.seenBy.first.username, 'bob');
      // Exact read timestamp round-trips (asDateTime normalizes to local).
      expect(msg.seenBy.first.lastReadAt?.toUtc(), t1);
      expect(msg.seenBy[1].lastReadAt, isNull);
    });

    test('fromRest with no seenBy is empty, toJson round-trips', () {
      final plain = ChatMessage.fromRest({'_id': 'm1', 'content': 'x'});
      expect(plain.seenBy, isEmpty);
      final withReaders = plain.copyWith(
        seenBy: const [SeenByUser(userId: 'bob', username: 'bob')],
      );
      final round = ChatMessage.fromRest(withReaders.toJson());
      expect(round.seenBy.single.userId, 'bob');
    });

    test('seenByOldestFirst sorts by read time, oldest first', () {
      final msg = _own('m1', 'hi', t0, seenBy: [
        SeenByUser(userId: 'bob', username: 'bob', lastReadAt: t2),
        SeenByUser(userId: 'carol', username: 'carol', lastReadAt: t0),
        SeenByUser(userId: 'dave', username: 'dave'), // no timestamp
        SeenByUser(userId: 'alice', username: 'alice', lastReadAt: t1),
      ]);
      final ordered = msg.seenByOldestFirst.map((s) => s.userId).toList();
      expect(ordered, ['carol', 'alice', 'bob', 'dave']);
    });

    test("WsEvent.fromJson parses 'read'", () {
      final event = WsEvent.fromJson({
        'type': 'read',
        'chatId': 'c1',
        'userId': 'bob',
        'username': 'bob',
        'lastReadMessage': 'm2',
        'lastReadAt': t1.toIso8601String(),
      });
      expect(event, isA<WsReadEvent>());
      final read = event as WsReadEvent;
      expect(read.userId, 'bob');
      expect(read.username, 'bob');
      expect(read.lastReadMessage, 'm2');
      // asDateTime normalizes to local time; compare instants.
      expect(read.lastReadAt?.toUtc(), t1);
    });
  });

  group('applyChatEvent read handling', () {
    test('upserts the reader cursor and attaches to my messages up to it', () {
      final state = ChatRoomState(messages: [
        _own('m1', 'hi', t0),
        _own('m2', 'yo', t1),
        _other('m3', 'x', t1),
      ]);
      final next = applyChatEvent(
        state,
        WsReadEvent(
          userId: 'bob',
          username: 'bob',
          lastReadMessage: 'm2',
          lastReadAt: t1,
        ),
        myUserId: 'me',
      );

      expect(next.readCursors['bob']?.username, 'bob');
      expect(next.readCursors['bob']?.lastReadAt, t1);
      expect(next.messages[0].seenBy.map((s) => s.userId), ['bob']);
      expect(next.messages[1].seenBy.map((s) => s.userId), ['bob']);
      // Other people's messages never carry the reader.
      expect(next.messages[2].seenBy, isEmpty);
    });

    test('messages after the cursor stay unread', () {
      final state = ChatRoomState(messages: [
        _own('m1', 'a', t0),
        _own('m2', 'b', t2),
      ]);
      final next = applyChatEvent(
        state,
        WsReadEvent(userId: 'bob', username: 'bob', lastReadAt: t1),
        myUserId: 'me',
      );
      expect(next.messages[0].seenBy, hasLength(1));
      expect(next.messages[1].seenBy, isEmpty);
    });

    test('without myUserId the cursor updates but seenBy is untouched', () {
      final state = ChatRoomState(messages: [_own('m1', 'hi', t0)]);
      final next = applyChatEvent(
        state,
        WsReadEvent(userId: 'bob', username: 'bob', lastReadAt: t1),
      );
      expect(next.readCursors['bob'], isNotNull);
      expect(next.messages.single.seenBy, isEmpty);
    });

    test('an existing reader is not duplicated', () {
      final state = ChatRoomState(messages: [
        _own('m1', 'hi', t0,
            seenBy: const [SeenByUser(userId: 'bob', username: 'bob')]),
      ]);
      final next = applyChatEvent(
        state,
        WsReadEvent(userId: 'bob', username: 'bob', lastReadAt: t1),
        myUserId: 'me',
      );
      expect(next.messages.single.seenBy, hasLength(1));
    });

    test("the sender's own read event never attaches them to their messages",
        () {
      // The backend broadcasts `read` to the whole room — including the
      // reader's own socket. My own ack must not show up as "Seen by me"
      // under my bubbles, and must not record my own cursor.
      final state = ChatRoomState(messages: [_own('m1', 'hi', t0)]);
      final next = applyChatEvent(
        state,
        WsReadEvent(userId: 'me', username: 'me', lastReadAt: t1),
        myUserId: 'me',
      );
      expect(next.messages.single.seenBy, isEmpty);
      expect(next.readCursors.containsKey('me'), isFalse);
    });
  });

  group('ChatRoomController.acknowledgeRead', () {
    test('sends a debounced read ack for the newest visible message', () async {
      final server = _MockReadServer();
      await server.start();
      addTearDown(server.close);

      final container = ProviderContainer(
        overrides: [
          chatRoomProvider.overrideWith(
            () => ChatRoomController(
              clientFactory: ({required onEvent, required onClose}) =>
                  WsClient<WsEvent>(
                url:
                    'ws://127.0.0.1:${server.port}/ws/chat?chatId=c1&token=test',
                parser: WsEvent.fromJson,
                onEvent: onEvent,
                onClose: onClose,
              ),
            ),
          ),
        ],
      );
      final sub = container.listen(chatRoomProvider('c1'), (_, _) {});
      addTearDown(() async {
        sub.close();
        container.dispose();
      });
      await server.clientConnected.future.timeout(const Duration(seconds: 5));

      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.acknowledgeRead('m1');
      final frame = await server.readReceived.future
          .timeout(const Duration(seconds: 5));
      expect(frame['type'], 'read');
      expect(frame['upToMessageId'], 'm1');

      // Same id again (e.g. a scroll event re-reporting the same message) is
      // deduped: no second frame.
      final before = server.frames.length;
      controller.acknowledgeRead('m1');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(server.frames.length, before);

      // A newer message produces a new ack.
      controller.acknowledgeRead('m2');
      await _waitFor(
        () => server.frames.any(
          (f) => f['type'] == 'read' && f['upToMessageId'] == 'm2',
        ),
      );
    });
  });
}

/// Minimal `/ws/chat` server that records every inbound frame.
class _MockReadServer {
  final List<Map<String, dynamic>> frames = [];
  final Completer<void> clientConnected = Completer<void>();
  final Completer<Map<String, dynamic>> readReceived =
      Completer<Map<String, dynamic>>();

  HttpServer? _http;
  WebSocket? _ws;

  Future<void> start() async {
    _http = await HttpServer.bind('127.0.0.1', 0);
    _http!.listen((request) async {
      if (request.uri.path == '/ws/chat') {
        final ws = await WebSocketTransformer.upgrade(request);
        _ws = ws;
        if (!clientConnected.isCompleted) clientConnected.complete();
        ws.listen((data) {
          if (data is! String) return;
          final json = jsonDecode(data) as Map<String, dynamic>;
          frames.add(json);
          if (json['type'] == 'read' && !readReceived.isCompleted) {
            readReceived.complete(json);
          }
        });
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });
  }

  int get port => _http!.port;

  Future<void> close() async {
    await _ws?.close();
    await _http?.close(force: true);
  }
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
