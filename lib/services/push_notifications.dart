// FCM push notifications (task 28).
//
// ⚠️ ENABLING THIS REQUIRES FIREBASE SETUP FIRST — see the task list /
// PLAN.md. The package is intentionally NOT in pubspec.yaml yet:
//
//   1. Create a Firebase project in the console (console.firebase.google.com).
//   2. Run `dart pub global activate flutterfire_cli` once, then
//      `flutterfire configure` in flutter-app/ — it registers the Android
//      app (package `com.example.chat_app`), creates `firebase_options.dart`,
//      and wires the google-services Gradle plugin for you.
//   3. `flutter pub add firebase_core firebase_messaging`
//   4. Uncomment the import + call sites below (marked with `PUSH:`) and
//      call `PushNotifications.init()` after sign-in.
//   5. Backend: set `FIREBASE_SERVICE_ACCOUNT=/path/to/service-account.json`
//      and register the token via `POST /user/push-token` (already
//      implemented).
//
// Until then this file is inert — nothing imports it.

// PUSH: uncomment when firebase_messaging is added
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:flutter/material.dart';

/// FCM wiring for the app. Call [init] after sign-in (it registers the
/// device token with the backend) and [dispose] on sign-out.
///
/// Foreground notifications are delivered to [onMessage]; tapping a
/// notification dispatches on its `type` data field: friend-request pushes
/// go to [onOpenRequests], everything else (chat messages) opens the chat
/// via [onOpenChat].
class PushNotifications {
  PushNotifications({
    required this.registerToken,
    required this.onMessage,
    required this.onOpenChat,
    this.onOpenRequests,
  });

  /// Sends the FCM token to `POST /user/push-token`.
  final Future<void> Function(String token) registerToken;

  /// Called for notifications received while the app is in the foreground.
  final void Function(String chatId)? onMessage;

  /// Called when the user taps a chat notification (foreground or background).
  final void Function(String chatId) onOpenChat;

  /// Called when the user taps a friend-request notification.
  final void Function()? onOpenRequests;

  bool _initializing = false;
  bool _initialized = false;

  /// Whether Firebase is available in this build. Returns false until the
  /// PUSH: steps above are completed.
  bool get isAvailable => _initialized;

  Future<void> init() async {
    // Re-entry guard: init() is invoked during widget build, so every
    // ClerkAuthBuilder rebuild would otherwise re-run the permission
    // request, listeners and token registration concurrently.
    if (_initializing || _initialized) return;
    _initializing = true;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Token refresh → keep the backend in sync.
      messaging.onTokenRefresh.listen((token) => registerToken(token));

      // Foreground messages.
      FirebaseMessaging.onMessage.listen((message) {
        if (_isFriendRequest(message)) {
          onOpenRequests?.call();
          return;
        }
        final chatId = message.data['chatId'];
        if (chatId != null && onMessage != null) onMessage!(chatId);
      });

      // Tap on a notification while the app is open.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _handleTap(message);
      });

      // App launched from a notification (cold start).
      final initial = await messaging.getInitialMessage();
      if (initial != null) _handleTap(initial);

      // Register the current token.
      final token = await messaging.getToken();
      if (token != null) await registerToken(token);
      _initialized = true;
    } catch (e) {
      // Firebase not configured for this platform — push disabled silently.
      debugPrint('Push notifications init skipped: $e');
    } finally {
      _initializing = false;
    }
  }

  bool _isFriendRequest(RemoteMessage message) =>
      message.data['type'] == 'friend-request';

  /// Routes a tapped notification by its data payload.
  void _handleTap(RemoteMessage message) {
    if (_isFriendRequest(message)) {
      onOpenRequests?.call();
      return;
    }
    final chatId = message.data['chatId'];
    if (chatId != null) onOpenChat(chatId);
  }

  Future<void> dispose() async {
    // PUSH: unregister the token if desired (backend has no endpoint yet).
    _initialized = false;
  }
}

/// Taps "Show" on a chat notification — opens the chat room.
void openChatFromNotification(
  BuildContext context,
  String chatId, {
  String chatName = 'Chat',
}) {
  // PUSH: navigate to ChatRoomScreen(chat: ChatSummary(id: chatId, ...)).
  // Requires a navigatorKey on MaterialApp to work from any state.
  // ignore: avoid_print
  print('PUSH: open chat $chatId ($chatName)');
}
