import 'dart:async';

import 'package:web/web.dart' as web;

/// Opens [url] in a named popup window and waits for it to land on the
/// app's own origin — the static `clerk-callback.html` page that the
/// `redirectionGenerator` points Clerk at. Because that page is
/// same-origin, the main window can read `popup.location.href` (which is
/// unreadable while the popup is on the provider's cross-origin page) and
/// pick up Clerk's `rotating_token_nonce`.
///
/// Returns the full callback URI so the caller can complete the sign-in
/// via `parseDeepLink` / `completeOAuthSignIn`.
Future<Uri> openPopupAndWait(
  String url, {
  required String callbackBase,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final popup = web.window.open(url, 'clerkGoogleOAuth');
  if (popup == null) {
    throw StateError(
      'The popup was blocked. Allow popups for this site and try again.',
    );
  }

  final deadline = DateTime.now().add(timeout);
  const pollInterval = Duration(milliseconds: 400);

  while (DateTime.now().isBefore(deadline)) {
    // Read the URL before checking `closed`: the callback page auto-closes
    // itself a moment after loading, so a popup that already landed on our
    // origin must still complete even if it has shut itself down.
    String? href;
    try {
      href = popup.location.href;
    } catch (_) {
      // Cross-origin (still on the provider page) or already closed.
    }

    if (href != null && href.startsWith(callbackBase)) {
      popup.close();
      return Uri.parse(href);
    }

    if (popup.closed) {
      throw StateError('Google sign-in was cancelled.');
    }

    await Future<void>.delayed(pollInterval);
  }

  popup.close();
  throw TimeoutException('Google sign-in timed out.');
}
