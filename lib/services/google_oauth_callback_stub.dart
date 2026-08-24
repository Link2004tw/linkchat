import 'dart:async';

/// Native fallback: the popup flow is web-only. Desktop uses the local HTTP
/// callback server in `google_oauth_callback.dart` instead; this is only
/// reachable if `waitForCallback` is somehow called with a popup URL off web.
Future<Uri> openPopupAndWait(
  String url, {
  required String callbackBase,
  Duration timeout = const Duration(minutes: 5),
}) {
  throw UnsupportedError('Google OAuth popup flow is only available on web.');
}
