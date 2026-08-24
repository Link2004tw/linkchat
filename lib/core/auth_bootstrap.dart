import 'dart:async';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'clerk_auth_config.dart';
import 'config.dart';

/// Creates the Clerk auth state, recovering from two startup failure modes
/// that would otherwise leave the app stuck on the loading spinner:
///
///  1. A stale/expired persisted session. The relay returns 401 and the SDK
///     throws `ClerkError` (e.g. `signed_out` / `noSessionTokenRetrieved`)
///     before any error listener exists. We drop the persisted client and
///     token cache, then recreate so the app lands on the sign-in screen.
///  2. A transient outage (backend/Clerk unreachable) → [TimeoutException] /
///     [SocketException] → retry with capped exponential backoff.
///
/// Only *session-fatal* errors wipe the persisted state. The SDK reports any
/// non-200 session-token refresh (relay 429/502/401 blip, rate-limit band,
/// ngrok hiccup) as a `ClerkError` too — deleting tokens for those would
/// destroy a perfectly valid login, so they take the retry path instead.
///
/// [giveUpAfter] caps the total retry window: once it elapses the function
/// returns null instead of looping forever, so callers that render UI first
/// (splash → error screen with Retry) never wedge on a white launch frame.
Future<ClerkAuthState?> createClerkAuthStateWithFallback({
  Duration giveUpAfter = const Duration(seconds: 30),
}) async {
  // Startup diagnostic: the web origin and API base must be CORS-compatible
  // for the Clerk relay to work from a browser. Surfaced once so a failed
  // `Failed to fetch` in the console can be matched to the actual origin.
  debugPrint(
    'auth bootstrap: kIsWeb=$kIsWeb base=${AppConfig.baseUrl} '
    'origin=${kIsWeb ? Uri.base : 'n/a'}',
  );
  final config = clerkAuthConfig(AppConfig.clerkPublishableKey);
  const clientKey = r'$client';
  // The SDK derives its token-cache keys from `publishableKey.hashCode`;
  // String.hashCode is stable, so this matches keys written by earlier runs.
  final cacheId = AppConfig.clerkPublishableKey.hashCode;
  final tokenKeys = [
    '_clerkSession_Id_$cacheId',
    '_clerkSession_Tokens_$cacheId',
    '_clerkClient_Token_$cacheId',
    '_clerkClient_Id_$cacheId',
  ];
  final deadline = DateTime.now().add(giveUpAfter);
  var attempt = 0;

  Future<void> wipePersistedAuth() async {
    await config.persistor.delete(clientKey);
    for (final key in tokenKeys) {
      await config.persistor.delete(key);
    }
  }

  for (;;) {
    try {
      return await ClerkAuthState.create(config: config);
    } on clerk.ClerkError catch (error) {
      debugPrint('Clerk init rejected (${error.code}): ${error.message}');
      if (isSessionFatalClerkError(error)) {
        // Stale/expired session → start over signed-out instead of wedging.
        await wipePersistedAuth();
        await _retryDelay(1);
      } else {
        // Transient relay/server failure — keep the persisted session and
        // back off; recreating would succeed with it once the relay recovers.
        await _retryDelay(++attempt);
      }
    } on TimeoutException {
      await _retryDelay(++attempt);
    } on SocketException {
      await _retryDelay(++attempt);
    } on http.ClientException {
      // On web, BrowserClient throws ClientException (not SocketException)
      // when the relay is unreachable or CORS is misconfigured.
      await _retryDelay(++attempt);
    }
    // Cap the total wait — surface failure to the caller (splash → error
    // screen with Retry) instead of spinning behind the white launch frame
    // indefinitely. Checked after each attempt so a single in-flight
    // `create` is always allowed to finish.
    if (DateTime.now().isAfter(deadline)) {
      debugPrint(
        'auth bootstrap: giving up after ${giveUpAfter.inSeconds}s of retries',
      );
      return null;
    }
  }
}

/// Whether this error means the persisted session is genuinely unusable and
/// must be dropped ([createClerkAuthStateWithFallback] wipes the persistor).
/// Everything else is treated as transient.
///
/// The SDK surfaces a failed session-token refresh as
/// [clerk.ClerkErrorCode.noSessionTokenRetrieved] no matter the HTTP cause
/// (relay 401/429/502 all land here), so code alone cannot fully distinguish
/// "expired" from "blip" — but an expired token is by far the most common
/// reason this fires at startup, and wiping costs one re-login while NOT
/// wiping on a true expiry wedges the poller in a failing loop.
bool isSessionFatalClerkError(clerk.ClerkError error) => switch (error.code) {
      clerk.ClerkErrorCode.noSessionTokenRetrieved => true,
      clerk.ClerkErrorCode.noSessionFoundForUser => true,
      clerk.ClerkErrorCode.jwtPoorlyFormatted => true,
      _ => false,
    };

Future<void> _retryDelay(int attempt) async {
  final seconds = 1 << (attempt > 4 ? 4 : attempt);
  debugPrint('Clerk backend unreachable — retrying in ${seconds}s…');
  await Future<void>.delayed(Duration(seconds: seconds));
}
