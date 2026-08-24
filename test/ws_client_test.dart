import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/ws_client.dart';

void main() {
  group('WsClient.redactedUrl', () {
    test('returns the URL verbatim when it carries a chatId', () {
      final client = WsClient<String>(
        url: 'ws://localhost:3001/ws/chat?chatId=c1',
        parser: (json) => '',
        onEvent: (_) {},
      );
      expect(client.redactedUrl, 'ws://localhost:3001/ws/chat?chatId=c1');
    });

    test('returns the URL verbatim for a chat-list URL', () {
      final client = WsClient<String>(
        url: 'ws://localhost:3001/ws/chat-list',
        parser: (json) => '',
        onEvent: (_) {},
      );
      expect(client.redactedUrl, 'ws://localhost:3001/ws/chat-list');
    });

    test('never contains auth material', () {
      // The JWT travels in the Sec-WebSocket-Protocol header, so the URL
      // must never carry it — redaction is a non-event by construction.
      final client = WsClient<String>(
        url: 'ws://localhost:3001/ws/chat?chatId=c1',
        parser: (json) => '',
        onEvent: (_) {},
      );
      expect(client.redactedUrl, isNot(contains('token=')));
      expect(client.redactedUrl, isNot(contains('SECRETJWT')));
    });
  });

  group('WsClient connection failures', () {
    test('captures the failure with the redacted URL', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen(
        (request) {
          // Refuse the WebSocket upgrade → the client sees a connection
          // error instead of an open channel.
          request.response.statusCode = HttpStatus.forbidden;
          request.response.close();
        },
        onError: (_) {},
      );

      final closed = Completer<void>();
      final client = WsClient<String>(
        url: 'ws://127.0.0.1:${server.port}/ws/chat?chatId=c1',
        parser: (json) => '',
        onEvent: (_) {},
        onClose: closed.complete,
      );
      addTearDown(client.dispose);

      await client.connect();
      await closed.future.timeout(const Duration(seconds: 5));

      expect(client.lastError, isNotNull);
      expect(
        client.lastError!.url,
        'ws://127.0.0.1:${server.port}/ws/chat?chatId=c1',
      );
      expect(client.lastError!.url, isNot(contains('token=')));
      expect(client.lastError!.message, isNotEmpty);
    });

    test('clears lastError on the next connect attempt', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen(
        (request) {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.close();
        },
        onError: (_) {},
      );

      Completer<void>? closed;
      final client = WsClient<String>(
        url: 'ws://127.0.0.1:${server.port}/ws/chat?chatId=c1',
        parser: (json) => '',
        onEvent: (_) {},
        onClose: () => closed?.complete(),
      );
      addTearDown(client.dispose);

      final firstClose = closed = Completer<void>();
      await client.connect();
      await firstClose.future.timeout(const Duration(seconds: 5));
      expect(client.lastError, isNotNull);

      // A fresh attempt resets the recorded failure.
      final secondClose = closed = Completer<void>();
      await client.connect();
      expect(client.lastError, isNull);
      await secondClose.future.timeout(const Duration(seconds: 5));
    });
  });
}
