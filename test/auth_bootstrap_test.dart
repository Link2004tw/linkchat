import 'dart:async';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/auth_bootstrap.dart';

void main() {
  group('isSessionFatalClerkError', () {
    test('session-fatal codes wipe the persisted session', () {
      const fatalCodes = [
        clerk.ClerkErrorCode.noSessionTokenRetrieved,
        clerk.ClerkErrorCode.noSessionFoundForUser,
        clerk.ClerkErrorCode.jwtPoorlyFormatted,
      ];
      for (final code in fatalCodes) {
        final error = clerk.ClerkError(code: code, message: '$code');
        expect(isSessionFatalClerkError(error), isTrue,
            reason: '$code must be session-fatal');
      }
    });

    test('transient relay failures keep the persisted session', () {
      // A non-200 from the backend relay (429 rate-limit band, 502 upstream
      // failure, 401 JWKS-gate miss) surfaces as one of these — wiping for
      // them destroyed valid logins on app restart.
      const transientCodes = [
        clerk.ClerkErrorCode.serverErrorResponse,
        clerk.ClerkErrorCode.externalError,
        clerk.ClerkErrorCode.tooManyRetries,
        clerk.ClerkErrorCode.unknownError,
        clerk.ClerkErrorCode.clientAppError,
      ];
      for (final code in transientCodes) {
        final error = code == clerk.ClerkErrorCode.externalError
            ? clerk.ClerkError.external(TimeoutException('relay'))
            : clerk.ClerkError(code: code, message: '$code');
        expect(isSessionFatalClerkError(error), isFalse,
            reason: '$code must be treated as transient');
      }
    });
  });
}
