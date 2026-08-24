import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Converts a decoded JSON frame into a typed event.
typedef WsParser<T> = T Function(Map<String, dynamic> json);

/// The last connection failure: the redacted target URL plus the error
/// message, so reconnect paths can surface *what* failed and *where*.
typedef WsFailure = ({String url, String message});

/// Thin wrapper around a backend WebSocket (`/ws/chat` or `/ws/chat-list`).
///
/// Generic over the parsed event type: the chat socket parses [WsEvent]s,
/// the chat-list socket parses [ChatListEvent]s. This is the transport layer:
/// higher layers own reconnect policies, token refresh and file uploads.
///
/// The server authenticates via the `Sec-WebSocket-Protocol` header: the
/// client offers `[wsSubprotocol, <jwt>]` and the server echoes back the
/// subprotocol; the JWT is never placed in the URL. The server closes with
/// 1008 on auth failure.
class WsClient<T> {
  WsClient({
    required this.url,
    required this.parser,
    required this.onEvent,
    this.onClose,
    this.protocols,
  });

  final String url;
  final WsParser<T> parser;

  /// Subprotocols offered in the handshake. The last entry carries the
  /// Clerk JWT (e.g. `['chat', <jwt>]`); the server echoes only the first.
  final List<String>? protocols;

  /// Called for every parsed inbound event.
  final void Function(T event) onEvent;

  /// Called once when the connection drops (after error or close).
  final void Function()? onClose;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _closed = true;

  /// The most recent connection failure, or null after a clean close or a
  /// successful connect.
  WsFailure? lastError;

  bool get isConnected => _channel != null;

  /// The target URL as logged/surfaced to the UI. The URL carries no auth
  /// material (the JWT travels in the `Sec-WebSocket-Protocol` header), so
  /// it is safe to display verbatim.
  String get redactedUrl => url;

  Future<void> connect() async {
    await dispose();
    _closed = false;
    lastError = null;
    final channel = WebSocketChannel.connect(
      Uri.parse(url),
      protocols: protocols,
    );
    _channel = channel;
    // Connection failures ALSO complete `channel.ready` with the error; an
    // unlistened `ready` future surfaces as an unhandled async exception in
    // the zone (the real source of the "unhandled WebSocketChannelException"
    // noise). The error itself is handled on the stream below — this just
    // consumes the `ready` error so it can't crash the app.
    // ignore: unawaited_futures
    channel.ready.then((_) {}, onError: (_) {});
    _subscription = channel.stream.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        _channel = null;
        lastError = (url: redactedUrl, message: error.toString());
        debugPrint(
          'WS connection failed: ${error.toString()} — $redactedUrl',
        );
        _handleClose();
      },
      onDone: () {
        _channel = null;
        // A server-initiated close is not a failure — keep lastError as-is
        // so a prior error isn't overwritten by an ordinary drop.
        _handleClose();
      },
      cancelOnError: true,
    );
  }

  void _handleClose() {
    if (_closed) return;
    _closed = true;
    onClose?.call();
  }

  void _onData(dynamic data) {
    if (data is String) {
      try {
        final json = jsonDecode(data);
        if (json is Map<String, dynamic>) {
          onEvent(parser(json));
        }
      } on Exception {
        // Unparseable frame — ignore; the connection-level error/close
        // handler decides whether to retry.
      }
      return;
    }
    // The server only sends JSON; binary frames are outbound (file uploads).
  }

  /// Sends a JSON-encodable payload (e.g. `{type: 'message', content: ...}`).
  void sendJson(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  /// Sends a raw binary frame (a file chunk for the upload protocol).
  void sendBinary(List<int> bytes) {
    _channel?.sink.add(bytes);
  }

  Future<void> dispose() async {
    _closed = true;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
  }
}
