import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/config.dart';

void main() {
  test('WebSocket URLs carry an explicit non-zero port', () {
    // dart:io's WebSocket.connect rebuilds the request URI with
    // `port: uri.port`, and Uri.port returns 0 for the wss scheme when no
    // port is given (only http/https get a scheme default). A port-less URL
    // would connect to port 0 and fail the handshake, so both chat and
    // chat-list URLs must always include an explicit port.
    for (final url in [
      AppConfig.chatWsUrl(chatId: 'c1'),
      AppConfig.chatListWsUrl(),
    ]) {
      final uri = Uri.parse(url);
      expect(uri.port, isNot(0), reason: '$url must carry an explicit port');
    }
  });

  test('https WS URL uses port 443 matching the TLS edge', () {
    expect(
      Uri.parse(AppConfig.chatListWsUrl()).port,
      AppConfig.useHttps ? 443 : AppConfig.apiPort,
    );
  });
}