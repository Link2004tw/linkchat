import 'dart:async';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
// The ClerkFileCache interface is only exported from the package's src/
// (its own internals import it the same way), so this is a deliberate
// implementation import.
// ignore: implementation_imports
import 'package:clerk_flutter/src/utils/clerk_file_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/google_oauth_callback.dart';
import 'config.dart';

/// Builds the Clerk auth config for the current platform.
///
/// Every platform routes Clerk API calls through our backend (`/api/clerk`):
/// on web because Clerk's FAPI forbids sending `Authorization` alongside the
/// browser `Origin` header; on desktop because this machine's direct path to
/// Clerk is flaky (drops TLS connections mid-response, crashing the SDK's
/// session-token poll). The relay is server-side, where IPv4 + retries absorb
/// that. See [ClerkProxyHttpService].
///
/// Persistence differs: web swaps in memory-only implementations (path_provider
/// has no web implementation, so the stock config throws
/// `MissingPluginException` during initialize()); native keeps the default
/// disk-backed persistor and image cache.
ClerkAuthConfig clerkAuthConfig(String publishableKey) {
  if (!kIsWeb) {
    return ClerkAuthConfig(
      publishableKey: publishableKey,
      httpService: const ClerkProxyHttpService(),
      // Desktop (Linux) has no SSO webview, so OAuth runs in the system
      // browser and comes back through [GoogleOAuthCallback]'s local HTTP
      // server. Returning null (e.g. before the server is up, or on web
      // where the Google button is hidden) makes Clerk fall back to its
      // default in-app webview flow.
      redirectionGenerator: (context, strategy) =>
          GoogleOAuthCallback.redirectUri,
    );
  }

  final memory = MemoryCachingPersistor();
  return ClerkAuthConfig(
    publishableKey: publishableKey,
    persistor: memory,
    fileCache: memory,
    httpService: const ClerkProxyHttpService(),
    // Web has no SSO webview either; Google OAuth runs in a popup that
    // lands on the same-origin static page `web/clerk-callback.html` (see
    // GoogleOAuthCallback).
    redirectionGenerator: (context, strategy) =>
        GoogleOAuthCallback.redirectUri,
  );
}

/// On web, browsers set the `Origin` header automatically. Clerk's front-end
/// API rejects any request carrying both `Origin` and `Authorization`, and the
/// client token can only be sent via `Authorization` — so direct browser →
/// Clerk calls fail once a token exists. This service rewrites those requests
/// to our backend (`/api/clerk/v1/*`), which relays them server-to-server
/// (no Origin header) where Authorization works.
class ClerkProxyHttpService extends clerk.DefaultHttpService {
  const ClerkProxyHttpService();

  /// Hard timeout for every relayed Clerk call. The underlying `http.Client`
  /// has no default timeout, so a hung connection to the backend relay (e.g.
  /// it is down) would block the SDK forever — including `signOut()`, which
  /// must always complete so the app can return to the login screen. On
  /// timeout the SDK retries (its own retry options), then `signOut()` fails
  /// fast and still flips the UI to the signed-out state.
  static const _relayTimeout = Duration(seconds: 8);

  bool _isClerkApi(Uri uri) =>
      uri.host.endsWith('clerk.accounts.dev') && uri.path.startsWith('/v1/');

  Uri _rewrite(Uri uri) {
    if (!_isClerkApi(uri)) return uri;
    // Relay through the same origin as the app's API base: 443 for the
    // default https public host, or the explicit http://LAN override port.
    // Hardcoding a port here breaks the https path (ngrok only listens on
    // 443, so :3001 hangs until the relay timeout fires).
    final base = Uri.parse(AppConfig.baseUrl);
    return uri.replace(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: '/api/clerk${uri.path}',
    );
  }

  @override
  Future<http.Response> send(
    clerk.HttpMethod method,
    Uri uri, {
    Map<String, String>? headers,
    Map<String, dynamic>? params,
    String? body,
  }) async {
    final response = await super
        .send(
          method,
          _rewrite(uri),
          headers: headers,
          params: params,
          body: body,
        )
        .timeout(_relayTimeout)
        .catchError(_convertBrowserError);
    _logIfFailed(method, uri, response.statusCode);
    return response;
  }

  @override
  Future<http.Response> sendByteStream(
    clerk.HttpMethod method,
    Uri uri,
    http.ByteStream byteStream,
    int length,
    Map<String, String> headers,
  ) async {
    final response = await super
        .sendByteStream(
          method,
          _rewrite(uri),
          byteStream,
          length,
          headers,
        )
        .timeout(_relayTimeout)
        .catchError(_convertBrowserError);
    _logIfFailed(method, uri, response.statusCode);
    return response;
  }

  /// Surfaces relay failures in the console: the SDK collapses any non-200
  /// into a generic Clerk error (and at init time, before an error listener
  /// exists, into a thrown `ClerkError`), so the actual status + endpoint is
  /// the only way to tell a rate-limit blip from a real outage.
  void _logIfFailed(clerk.HttpMethod method, Uri originalUri, int status) {
    if (status < 400) return;
    debugPrint(
      'Clerk relay: ${method.name.toUpperCase()} '
      '${_rewrite(originalUri)} → HTTP $status',
    );
  }

  /// On web, `BrowserClient` throws `ClientException` for network failures
  /// (backend unreachable, CORS preflight blocked, ngrok interstitial).
  /// Native platforms throw `SocketException` for the same condition.
  /// The Clerk SDK's internal session polling handles `SocketException`
  /// gracefully; `ClientException` escapes as an unhandled zone error.
  /// Normalize by converting so the SDK retries consistently on all
  /// platforms.
  static Never _convertBrowserError(Object error, StackTrace stack) {
    if (error is http.ClientException) {
      throw SocketException('Clerk relay unreachable: ${error.message}');
    }
    Error.throwWithStackTrace(error, stack);
  }

  /// Clerk's SDK pings the FAPI (e.g. `HEAD /v1/health`) to check
  /// connectivity. Relaying this through our backend fails because the
  /// backend doesn't handle `/api/clerk/v1/health` (it only proxies the
  /// routes it knows about). Returning `true` lets Clerk assume the API
  /// is reachable — actual API calls will surface real errors if the
  /// relay is truly down.
  @override
  Future<bool> ping(Uri uri, {required Duration timeout}) async => true;
}

/// In-memory [clerk.Persistor] that also satisfies the [ClerkFileCache]
/// interface (mirrors clerk_flutter's `DefaultCachingPersistor`, minus disk).
class MemoryCachingPersistor implements clerk.Persistor, ClerkFileCache {
  final Map<String, dynamic> _cache = <String, dynamic>{};

  @override
  Future<void> initialize() async {}

  @override
  void terminate() {}

  @override
  FutureOr<T?> read<T>(String key) => _cache[key] as T?;

  @override
  FutureOr<void> write<T>(String key, T value) {
    _cache[key] = value;
  }

  @override
  FutureOr<void> delete(String key) {
    _cache.remove(key);
  }

  @override
  Stream<File> stream(
    Uri uri, {
    Duration ttl = ClerkFileCache.defaultTTL,
    Map<String, String>? headers,
  }) async* {}
}
