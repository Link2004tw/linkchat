import 'dart:io' show Platform;

import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/deep_link.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_list_provider.dart';
import '../providers/push_provider.dart';
import '../utils/snack.dart';
import '../widgets/battery_prompt.dart';
import '../widgets/friend_notification_listener.dart';
import 'email_auth_screen.dart';
import 'home_shell.dart';

/// Bridges Clerk's auth state into Riverpod and switches between the
/// prebuilt sign-in UI and the main app.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start the deep-link listener once (provider caches its value), so
    // invite links arriving while signed out are parked for after sign-in.
    ref.watch(deepLinkInitProvider);
    return ClerkErrorListener(
      handler: (context, error) async {
        // Always log the raw error — the snackbar only shows `argument`, and
        // many failures collapse to a useless "Unknown error" there.
        debugPrint(
          'Clerk error: code=${error.code} message=${error.message} '
          'argument=${error.argument}',
        );
        // Clerk can emit an error mid-frame before the current screen's
        // Scaffold is registered (its default handler asserts on web in
        // debug). Defer the SnackBar to the next frame and fall back to a
        // log when no Scaffold is available.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // `error.message` is often a template like `{arg} (ERROR RECEIVED
          // FROM SERVER)`; `argument` carries the real message from the server.
          final message = error.argument ?? error.message;
          try {
            showSnack(context, message);
          } catch (_) {
            debugPrint('Clerk error (no Scaffold yet): $message');
          }
        });
      },
      child: ClerkAuthBuilder(
        builder: (context, authState) => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        signedInBuilder: (context, authState) {
          // Clerk re-invokes this builder during the build phase; Riverpod
          // forbids modifying providers there, so defer until the frame is
          // done. `attach` skips identical instances, so re-invocations are
          // cheap no-ops.
          Future.microtask(() {
            ref.read(clerkAuthProvider.notifier).attach(authState);
            // A deep-link invite code parked while signed out is consumed
            // once the navigator is up (post-frame).
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => consumePendingInvite(ref),
            );
          });
          // Register the FCM token on sign-in
          ref.read(pushNotificationsProvider).init();
          // OEM phones: ask once for the battery-optimization exemption so
          // swiped-away apps keep receiving FCM.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) maybeShowBatteryPrompt(context, ref);
          });
          return const FriendNotificationListener(child: HomeShell());
        },
        signedOutBuilder: (context, authState) {
          Future.microtask(() {
            ref.read(clerkAuthProvider.notifier).attach(authState);
            // Stop the chat-list socket and drop the offline cache on
            // sign-out so one account's chats don't leak into the next.
            ref.invalidate(chatListEventsProvider);
            ref.read(chatCacheProvider).clear();
          });
          // Unregister push on sign-out
          ref.read(pushNotificationsProvider).dispose();
          // Clerk's SSO webview has no Linux or web implementation, so use a
          // Google-free email/password screen there. Android keeps the full
          // prebuilt widget (Google OAuth included).
          if (kIsWeb) return const EmailAuthScreen();
          if (Platform.isLinux) return const EmailAuthScreen();
          return const ClerkAuthentication();
        },
      ),
    );
  }
}
