import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/ws_client.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';

/// Minimal in-test replica of the backend's `/ws/chat` upload protocol:
///   file-start → file-ack → binary chunk(s) → file-progress
///               → message broadcast + file-complete.
///
/// This lets the full client upload pipeline (ack-wait, chunk streaming,
/// progress rows, completion) run against a real socket without a backend.
class _MockChatServer {
  _MockChatServer({this.rejectFileStart = false, this.silent = false});

  final bool rejectFileStart;

  /// When true, accept a `file-start` but never respond — simulates a
  /// backend that lost the ack, so the client hits its own timeout.
  final bool silent;
  final List<int> receivedBytes = [];
  final Completer<void> clientConnected = Completer<void>();
  final Completer<void> uploadComplete = Completer<void>();

  HttpServer? _http;
  WebSocket? _ws;
  int _declaredSize = 0;
  int _received = 0;

  Future<void> start() async {
    _http = await HttpServer.bind('127.0.0.1', 0);
    _http!.listen((request) async {
      if (request.uri.path == '/ws/chat') {
        final ws = await WebSocketTransformer.upgrade(request);
        _ws = ws;
        if (!clientConnected.isCompleted) clientConnected.complete();
        ws.listen(_onData);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });
  }

  int get port => _http!.port;

  void _onData(dynamic data) {
    if (data is String) {
      final json = jsonDecode(data) as Map<String, dynamic>;
      if (json['type'] == 'file-start') {
        if (rejectFileStart) {
          _send({'type': 'error', 'text': 'Bad file metadata'});
          return;
        }
        if (silent) return;
        _declaredSize = (json['size'] as num).toInt();
        _received = 0;
        _send({'type': 'file-ack', 'status': 'started'});
      }
      return;
    }
    // Binary chunk from the client.
    final chunk = data as List<int>;
    receivedBytes.addAll(chunk);
    _received += chunk.length;
    final progress = _declaredSize == 0
        ? 100
        : (_received * 100 ~/ _declaredSize).clamp(0, 100);
    _send({'type': 'file-progress', 'progress': progress});
    if (_received >= _declaredSize) {
      _send({
        'type': 'message',
        'messageId': 'm1',
        'content': 'https://example.com/a.png',
        'contentType': 'image',
        'fileName': 'a.png',
        'mimeType': 'image/png',
        'fileSize': _declaredSize,
        'author': {'_id': 'u1', 'userId': 'u1', 'username': 'alice'},
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
      _send({
        'type': 'file-complete',
        'messageId': 'm1',
        'url': 'https://example.com/a.png',
      });
      if (!uploadComplete.isCompleted) uploadComplete.complete();
    }
  }

  void _send(Map<String, dynamic> payload) {
    _ws?.add(jsonEncode(payload));
  }

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

/// Starts a mock server and a live controller wired to it. The autoDispose
/// provider is kept alive with a subscription so its socket survives the
/// whole test.
Future<
  (
    _MockChatServer server,
    ProviderContainer container,
    ChatRoomController controller,
  )
>
_setup({
  bool rejectFileStart = false,
  bool silent = false,
  Duration fileStartAckTimeout = const Duration(seconds: 10),
}) async {
  final server = _MockChatServer(
    rejectFileStart: rejectFileStart,
    silent: silent,
  );
  // Bind first so the client factory sees a valid port when it builds.
  await server.start();
  final container = ProviderContainer(
    overrides: [
      markChatAsReadProvider.overrideWithValue((_) {}),
      chatRoomProvider.overrideWith(
        () => ChatRoomController(
          fileStartAckTimeout: fileStartAckTimeout,
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
  return (server, container, container.read(chatRoomProvider('c1').notifier));
}

void main() {
  test('happy path: upload streams chunks and lands as a message', () async {
    final (server, container, controller) = await _setup();
    addTearDown(server.close);
    final sub = container.listen(chatRoomProvider('c1'), (_, _) {});
    addTearDown(() async {
      sub.close();
      container.dispose();
    });
    await server.clientConnected.future.timeout(const Duration(seconds: 5));

    // ~3 chunks of the 128 KB client chunk size.
    final bytes = List<int>.generate(300 * 1024, (i) => i % 251);
    final result = await controller.sendFile(
      name: 'a.png',
      bytes: bytes,
      mime: 'image/png',
    );
    expect(result, isNull, reason: 'a successful upload returns null');

    await server.uploadComplete.future.timeout(const Duration(seconds: 5));
    expect(server.receivedBytes, bytes);

    await _waitFor(
      () => container.read(chatRoomProvider('c1')).messages.isNotEmpty,
    );
    final state = container.read(chatRoomProvider('c1'));
    expect(state.messages.single.content, 'https://example.com/a.png');
    expect(state.messages.single.contentType, 'image');
    expect(
      state.uploads,
      isEmpty,
      reason: 'file-complete removes the progress row',
    );
    expect(state.lastError, isNull);
  });

  test(
    'rejected file-start returns the reason and sends no binary data',
    () async {
      final (server, container, controller) = await _setup(
        rejectFileStart: true,
      );
      addTearDown(server.close);
      final sub = container.listen(chatRoomProvider('c1'), (_, _) {});
      addTearDown(() async {
        sub.close();
        container.dispose();
      });
      await server.clientConnected.future.timeout(const Duration(seconds: 5));

      final result = await controller.sendFile(
        name: 'a.png',
        bytes: [1, 2, 3],
        mime: 'image/png',
      );
      expect(result, 'Bad file metadata');
      expect(
        server.receivedBytes,
        isEmpty,
        reason: 'a rejected file-start must not stream chunks',
      );
      expect(container.read(chatRoomProvider('c1')).uploads, isEmpty);
    },
  );

  test('unresponsive server surfaces a timeout instead of hanging', () async {
    final (server, container, controller) = await _setup(
      silent: true,
      fileStartAckTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(server.close);
    final sub = container.listen(chatRoomProvider('c1'), (_, _) {});
    addTearDown(() async {
      sub.close();
      container.dispose();
    });
    await server.clientConnected.future.timeout(const Duration(seconds: 5));

    // The server never sends the ack — the client must give up on its own.
    final result = await controller.sendFile(
      name: 'a.png',
      bytes: [1, 2, 3],
      mime: 'image/png',
    );
    expect(result, contains('acknowledge'));
    expect(container.read(chatRoomProvider('c1')).uploads, isEmpty);
  });
}
