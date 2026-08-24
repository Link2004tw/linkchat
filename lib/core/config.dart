/// Central app configuration.
///
/// The API host is injected at build/run time via `--dart-define`:
/// ```
/// flutter run --dart-define=API_HOST=192.168.1.20                       # bare host
/// flutter run --dart-define=API_HOST=http://192.168.1.20:3001           # full http URL
/// flutter run --dart-define=API_HOST=https://my-domain                  # full https URL
/// ```
/// By default the app talks to the public backend URL (the Fastify server on
/// this machine exposed through ngrok over https), so it works from any
/// device without extra flags. The backend and its database are co-located on
/// the same device. When developing on the same machine, override with a LAN
/// IP or localhost.
///
/// The backend (Fastify) listens on port 3001 by default (server.ts; a
/// `PORT` in backend/.env can override it) and binds 0.0.0.0. The public URL
/// is https/wss (no port); the http scheme with an explicit port is used only
/// for LAN/local overrides.
class AppConfig {
  AppConfig._();

  /// Default public backend host (ngrok → the Fastify server on this device).
  static const String _defaultApiHost =
      'flirtatiously-chalcolithic-bria.ngrok-free.dev';

  static const String _apiHostOverride = String.fromEnvironment('API_HOST');

  /// Whether the override was given as a full `https://` URL.
  static bool get _overrideIsHttps => _apiHostOverride.startsWith('https://');

  /// The backend host. If the override is a full URL its scheme is stripped;
  /// a bare override (or no override) is used as-is.
  static String get apiHost {
    final override = _apiHostOverride;
    if (override.isNotEmpty) {
      final schemeEnd = override.indexOf('://');
      return schemeEnd == -1 ? override : override.substring(schemeEnd + 3);
    }
    return _defaultApiHost;
  }

  /// Clerk publishable key (public by design). The default is the test key
  /// for the shared Clerk instance (serves chat-demo and this native app),
  /// so plain `flutter run` works without flags. Override per environment
  /// with:
  /// `flutter run --dart-define=CLERK_PUBLISHABLE_KEY=pk_test_...`
  static const String _clerkPublishableKeyOverride = String.fromEnvironment(
    'CLERK_PUBLISHABLE_KEY',
  );

  static String get clerkPublishableKey {
    if (_clerkPublishableKeyOverride.isNotEmpty) return _clerkPublishableKeyOverride;
    return 'pk_test_aGFybWxlc3MtYnVubnktMzkuY2xlcmsuYWNjb3VudHMuZGV2JA';
  }

  /// Whether the backend is reached over TLS. The public URL defaults to
  /// https; only an explicit `http://` override opts out.
  static bool get useHttps {
    if (_apiHostOverride.isNotEmpty) return _overrideIsHttps;
    return true;
  }

  /// http:// override port (ignored for the https public URL). Local LAN
  /// backends default to 3001 like the Fastify server.
  static const int apiPort = int.fromEnvironment(
    'API_PORT',
    defaultValue: 3001,
  );

  /// REST base URL: `https://host` (443, no port) or `http://host:port`.
  static String get baseUrl {
    final host = apiHost;
    if (useHttps) return 'https://$host';
    return 'http://$host:$apiPort';
  }

  /// Full URL for a REST endpoint, e.g. `api('/chats/all')` → `https://.../api/chats/all`.
  static String api(String path) => '$baseUrl/api$path';

  /// WebSocket base: `wss://host:443` or `ws://host:port`.
  ///
  /// The https branch must carry an explicit port: dart:io's
  /// `WebSocket.connect` rebuilds the request URI with `port: uri.port`, and
  /// `Uri.port` returns 0 for the `wss` scheme when no port is given (only
  /// http/https get a default). A port-less `wss://host` would connect to
  /// port 0 and fail the handshake.
  static String get _wsBaseUrl {
    final host = apiHost;
    if (useHttps) return 'wss://$host:443';
    return 'ws://$host:$apiPort';
  }

  /// Chat WebSocket subprotocol: offered first so the server echoes it back
  /// in the 101 handshake. The Clerk JWT rides along in the same
  /// `Sec-WebSocket-Protocol` header (never in the URL, which would leak
  /// into logs and browser history).
  static const String wsSubprotocol = 'chat';

  /// Chat WebSocket URL (one connection per open room). The auth token is
  /// passed separately via [WsClient.protocols], not in the URL.
  static String chatWsUrl({required String chatId}) =>
      '$_wsBaseUrl/ws/chat?chatId=$chatId';

  /// Chat-list WebSocket URL (single connection for the whole session).
  /// The auth token is passed separately via [WsClient.protocols].
  static String chatListWsUrl() => '$_wsBaseUrl/ws/chat-list';
}