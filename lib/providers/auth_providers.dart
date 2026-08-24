import 'dart:async';

import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/user.dart';

/// Lightweight wrapper around [ClerkAuthState] that forces Riverpod to emit
/// a new value on every real auth change.
///
/// Clerk reuses and mutates the same [ClerkAuthState] instance across
/// sign-out → sign-in transitions, so a raw identity check (`identical`)
/// never detects changes.  [AuthSnapshot] carries a [revision] counter that
/// bumps whenever [ClerkAuthController.attach] sees a different user or
/// sign-in status, guaranteeing derived providers rebuild.
class AuthSnapshot {
  const AuthSnapshot(this.auth, this.revision);
  final ClerkAuthState? auth;
  final int revision;

  bool get isSignedIn => auth?.isSignedIn ?? false;
  String? get userId => auth?.user?.id;
}

/// The ClerkAuthState is created inside Clerk's widget tree. [AuthGate]
/// hands it to this controller so Riverpod code can reach the session,
/// user and token.
class ClerkAuthController extends Notifier<AuthSnapshot?> {
  final Completer<void> _ready = Completer<void>();
  int _revision = 0;
  String? _lastUserId;
  bool _lastIsSignedIn = false;

  /// Completes once [attach] has delivered the Clerk auth state.
  ///
  /// AuthGate schedules `attach` as a microtask *after* the signed-in frame,
  /// so REST calls made in that same frame (e.g. the Friends tab, which is
  /// built eagerly inside HomeShell's IndexedStack) would otherwise see a
  /// null state and fail with a spurious 401. Awaiting [ready] turns that
  /// into a loading spinner until authentication is confirmed.
  Future<void> get ready => _ready.future;

  @override
  AuthSnapshot? build() => null;

  /// Attach the auth state provided by Clerk's `ClerkAuthBuilder`.
  ///
  /// Detects real transitions by comparing [userId] and [isSignedIn] against
  /// the previous snapshot, then bumps [revision] so Riverpod emits a new
  /// value even though the underlying [ClerkAuthState] instance is reused.
  void attach(ClerkAuthState? authState) {
    final userId = authState?.user?.id;
    final isSignedIn = authState?.isSignedIn ?? false;

    if (userId == _lastUserId && isSignedIn == _lastIsSignedIn) return;
    _lastUserId = userId;
    _lastIsSignedIn = isSignedIn;
    _revision++;
    state = AuthSnapshot(authState, _revision);
    if (!_ready.isCompleted) _ready.complete();
  }
}

final clerkAuthProvider =
    NotifierProvider<ClerkAuthController, AuthSnapshot?>(ClerkAuthController.new);

/// Whether the user currently has a Clerk session.
final isSignedInProvider = Provider<bool>(
  (ref) => ref.watch(clerkAuthProvider)?.isSignedIn ?? false,
);

/// The signed-in user mapped to our `ChatUser` model (for UI display).
final currentUserProvider = Provider<ChatUser?>((ref) {
  final user = ref.watch(clerkAuthProvider)?.auth?.user;
  if (user == null) return null;
  return ChatUser(
    clerkId: user.id,
    username: user.username ?? user.firstName ?? user.id,
    firstName: user.firstName,
    profileImageUrl: user.imageUrl ?? user.profileImageUrl,
  );
});

/// REST client that fetches a fresh Clerk JWT on every request.
///
/// The backend expects `Authorization: Bearer <jwt>`; `auth.sessionToken()`
/// returns the current (renewing) token, so no manual refresh is needed
/// here — a new token is simply fetched for the next call.
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(getToken: () async {
    final notifier = ref.read(clerkAuthProvider.notifier);
    // The first requests of a signed-in frame can fire before AuthGate's
    // microtask attaches the auth state; wait for it (the UI shows a
    // spinner meanwhile) rather than failing with a spurious 401.
    if (ref.read(clerkAuthProvider) == null) {
      await notifier.ready.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw ApiException(401, 'Not authenticated'),
      );
    }
    final auth = ref.read(clerkAuthProvider)?.auth;
    if (auth == null || !auth.isSignedIn) return null;
    final token = await auth.sessionToken();
    return token.jwt;
  });
});

