import 'dart:async';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_oauth_callback.dart';

/// Google OAuth orchestration, extracted from `EmailAuthScreen`: prepares
/// the flow via [ClerkAuthState.oauthSignIn], opens the provider page (web:
/// a same-origin popup we can observe; desktop: the system browser), waits
/// for the callback through [GoogleOAuthCallback], and completes sign-in via
/// [ClerkAuthState.parseDeepLink].
///
/// There is no SSO webview on desktop or web, so the callback is handled per
/// platform by [GoogleOAuthCallback]: on desktop the system browser opens and
/// comes back to a local HTTP server; on web a same-origin popup is opened
/// and polled.
///
/// Every step is logged so a failed attempt can be traced from the console
/// (the generic "unknown error" snackbar carries no detail). Errors that
/// don't go through Clerk's error stream get a specific, actionable message
/// instead of the SDK's fallback.
Future<void> completeGoogleOAuth(
  BuildContext context, {
  required ClerkAuthState auth,

  /// Called when a brand-new Google user still owes required sign-up
  /// fields; the host screen switches to its continuation form to collect
  /// exactly those fields.
  required void Function(List<clerk.Field> missingFields) onMissingFields,
}) async {
  await auth.safelyCall(
    context,
    () async {
      debugPrint('[googleSignIn] starting OAuth flow (platform: '
          '${kIsWeb ? 'web' : 'native'})');
      await GoogleOAuthCallback.ensureServer();
      final redirect = GoogleOAuthCallback.redirectUri;
      debugPrint('[googleSignIn] callback transport ready, '
          'redirect=$redirect');
      if (redirect == null) {
        auth.handleError(
          clerk.ClerkError.clientAppError(
            message: 'Google sign-in is not available on this platform.',
          ),
        );
        return;
      }
      if (!context.mounted) return;

      String? popupUrl;
      if (kIsWeb) {
        // Web: drive the popup ourselves — ssoSignIn's launchUrl opens a
        // tab we can't observe. oauthSignIn prepares the flow and exposes
        // the provider URL; the popup then lands on our same-origin
        // callback page where we can read the nonce.
        debugPrint('[googleSignIn] web: preparing OAuth popup');
        await auth.oauthSignIn(
          strategy: clerk.Strategy.oauthGoogle,
          redirect: redirect,
        );
        popupUrl = auth
            .signIn
            ?.firstFactorVerification
            ?.externalVerificationRedirectUrl;
        debugPrint('[googleSignIn] popup url obtained: '
            '${popupUrl == null ? 'null' : '<${popupUrl.length} chars>'}');
        if (popupUrl == null) {
          auth.handleError(
            clerk.ClerkError.clientAppError(
              message: 'Google sign-in didn\'t start. Please try again.',
            ),
          );
          return;
        }
      } else {
        // Desktop: same approach as web — use oauthSignIn to get the
        // provider URL, then open it in the system browser and wait
        // for the redirect to come back through our callback server.
        // ssoSignIn handles the redirect internally via Clerk's own
        // mechanism, so our local callback server never receives it,
        // causing the timeout.
        debugPrint('[googleSignIn] native: oauthSignIn + url_launcher');
        await auth.oauthSignIn(
          strategy: clerk.Strategy.oauthGoogle,
          redirect: redirect,
        );
        final providerUrl = auth
            .signIn
            ?.firstFactorVerification
            ?.externalVerificationRedirectUrl;
        debugPrint('[googleSignIn] provider url obtained: '
            '${providerUrl == null ? 'null' : '<present>'}');
        if (providerUrl == null) {
          auth.handleError(
            clerk.ClerkError.clientAppError(
              message: 'Google sign-in didn\'t start. Please try again.',
            ),
          );
          return;
        }
        final uri = Uri.parse(providerUrl);
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          auth.handleError(
            clerk.ClerkError.clientAppError(
              message: 'Could not open browser for Google sign-in.',
            ),
          );
          return;
        }
      }

      final Uri callback;
      debugPrint('[googleSignIn] waiting for callback...');
      try {
        callback =
            await GoogleOAuthCallback.waitForCallback(popupUrl: popupUrl);
      } on TimeoutException catch (error, stack) {
        debugPrint('[googleSignIn] callback timed out: $error\n$stack');
        auth.handleError(
          clerk.ClerkError.clientAppError(
            message: 'Google sign-in timed out. If the browser opened, '
                'make sure the redirect URL http://127.0.0.1:*/* is '
                'allowed in the Clerk dashboard (Instance → Redirect URLs).',
          ),
        );
        return;
      } on StateError catch (error) {
        // User closed the browser / popup before the redirect arrived.
        debugPrint('[googleSignIn] sign-in cancelled: $error');
        return;
      } on Exception catch (error, stack) {
        debugPrint('[googleSignIn] callback transport failed: $error\n$stack');
        rethrow;
      }
      debugPrint('[googleSignIn] callback received: ${callback.host}:'
          '${callback.port}${callback.path} '
          'queryKeys=${callback.queryParameters.keys}');

      debugPrint('[googleSignIn] completing via parseDeepLink...');
      await auth.parseDeepLink(callback);
      debugPrint('[googleSignIn] parseDeepLink done: '
          'signedIn=${auth.isSignedIn}; '
          'signUpMissing=${auth.signUp?.missingFields.length ?? 0}');

      // A brand-new Google user may still owe required sign-up fields.
      // Hand them back so the host form can collect exactly those fields.
      if (!auth.isSignedIn && context.mounted) {
        final signUp = auth.signUp;
        if (signUp != null && signUp.missingFields.isNotEmpty) {
          debugPrint('[googleSignIn] Google sign-up needs more fields: '
              '${signUp.missingFields.map((f) => f.title).toList()}');
          onMissingFields(List<clerk.Field>.of(signUp.missingFields));
        } else {
          debugPrint('[googleSignIn] not signed in and no missing fields '
              'to collect');
        }
      }
    },
  );
}
