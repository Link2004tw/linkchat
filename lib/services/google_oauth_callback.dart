import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'google_oauth_callback_stub.dart'
    if (dart.library.js_interop) 'google_oauth_callback_web.dart' as platform;

/// OAuth callback transport for Clerk Google login, per platform:
///
/// * **Desktop (Linux/macOS/Windows)** — a local HTTP server on loopback.
///   Clerk's `redirectionGenerator` is pointed at `http://127.0.0.1:<port>`
///   and `oauthSignIn` + `url_launcher` opens the provider in the system
///   browser (`LaunchMode.externalApplication`) instead of the in-app SSO
///   webview (which has no Linux implementation). `ssoSignIn` is avoided
///   because it handles the redirect internally via Clerk's own mechanism,
///   bypassing our callback server. When Google finishes, Clerk redirects
///   the browser to our URL with the `rotating_token_nonce`; the server
///   catches it, shows a tiny "close this window" page, and hands the URL
///   to the app so it can call `parseDeepLink`.
///
/// * **Web** — no TCP listener is possible in browser JS. Instead the
///   callback is the static same-origin page `web/clerk-callback.html`
///   (served next to the app). The OAuth URL is opened in a named popup and
///   polled (see `google_oauth_callback_web.dart`); once the popup lands on
///   our origin the main window can read its URL and the nonce.
class GoogleOAuthCallback {
  GoogleOAuthCallback._();

  static HttpServer? _server;
  static Uri? _redirectUri;
  static final List<Completer<Uri>> _pending = <Completer<Uri>>[];

  /// The redirect URL Clerk should send the browser back to, or null when
  /// unavailable (before [ensureServer] on desktop, or on a non-http origin
  /// on web).
  static Uri? get redirectUri {
    if (kIsWeb) {
      final base = Uri.base;
      if (base.scheme != 'http' && base.scheme != 'https') return null;
      return base.resolve('clerk-callback.html');
    }
    return _redirectUri;
  }

  /// Prepares the callback transport: starts the local listener on desktop
  /// (no-op on web, where the callback is the static page). Returns the
  /// redirect URL to hand to Clerk.
  static Future<Uri> ensureServer() async {
    if (kIsWeb) {
      final uri = redirectUri;
      if (uri == null) {
        throw StateError('Google sign-in needs an http(s) page origin.');
      }
      return uri;
    }

    if (_server case HttpServer server) {
      return Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/clerk-callback',
      );
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _redirectUri = Uri.parse('http://127.0.0.1:${server.port}/clerk-callback');

    server.listen((HttpRequest request) async {
      if (request.uri.path != '/clerk-callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final callback = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null,
      );

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!DOCTYPE html><html><body style="font-family:sans-serif;'
          'text-align:center;padding-top:4rem">'
          '<h3>Signed in! You can close this window and return to the app.</h3>'
          '</body></html>',
        );
      await request.response.close();

      _complete(callback);
    });

    return _redirectUri!;
  }

  /// Waits for the browser redirect that completes a sign-in.
  ///
  /// Web: [popupUrl] is the provider's verification URL; it is opened in a
  /// popup and polled until it lands on the callback page. Desktop: waits
  /// on the local HTTP server. One pending completer per in-flight OAuth
  /// attempt; a generous timeout so a user who abandons the browser doesn't
  /// leave the UI busy forever.
  static Future<Uri> waitForCallback({
    String? popupUrl,
    Duration timeout = const Duration(minutes: 5),
  }) {
    if (kIsWeb) {
      final base = redirectUri;
      if (popupUrl == null || base == null) {
        throw StateError('Google popup sign-in is not ready.');
      }
      return platform.openPopupAndWait(
        popupUrl,
        callbackBase: base.toString(),
        timeout: timeout,
      );
    }

    final completer = Completer<Uri>();
    _pending.add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(completer);
      throw TimeoutException('Google sign-in timed out.');
    });
  }

  static void _complete(Uri uri) {
    if (_pending.isEmpty) return;
    final completer = _pending.removeAt(0);
    if (!completer.isCompleted) completer.complete(uri);
  }

  /// Abandons every in-flight OAuth wait. Completes each pending completer
  /// with a [StateError] so callers can distinguish cancellation from a
  /// normal timeout. Useful when the user closes the browser / popup
  /// before the redirect arrives.
  static void cancelPending() {
    while (_pending.isNotEmpty) {
      final completer = _pending.removeAt(0);
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Google sign-in was cancelled.'),
        );
      }
    }
  }

  /// Stops the listener (mostly useful for tests).
  static Future<void> dispose() async {
    cancelPending();
    await _server?.close(force: true);
    _server = null;
    _redirectUri = null;
  }
}
