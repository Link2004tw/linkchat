// FCM push wiring (task 28) — the 5-minute enablement file.
//
// Everything below is inert until you've done the Firebase setup (PLAN.md
// Phase 7 / RUN.md §2). The plan:
//
//   1. Firebase console → create project
//   2. cd flutter-app && flutterfire configure   (writes lib/firebase_options.dart)
//   3. The firebase_core + firebase_messaging packages are ALREADY in
//      pubspec.yaml (added during the build fix).
//   4. Do the edits marked [PUSH] below — uncomment, don't rewrite.
//   5. Backend: FIREBASE_SERVICE_ACCOUNT + restart. Done.

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../firebase_options.dart';

/// Called from `main()` BEFORE `runApp`. With Firebase configured this
/// initializes the SDK (required before any messaging call).
///
/// Silently skips on platforms not configured in firebase_options.dart
/// (e.g. Linux desktop) so the app still runs without push.
Future<void> initializeFirebaseIfAvailable() async {
  // Only initialize on platforms that have Firebase options configured.
  if (!kIsWeb && !Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS && !Platform.isWindows) {
    return;
  }
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Firebase not configured for this platform — push disabled, app continues.
    debugPrint('Firebase init skipped: $e');
  }
}

/// Creates the app's push controller. Call [init] after sign-in,
/// [dispose] on sign-out.
///
/// [PUSH] Once `firebase_messaging` is imported, replace the stub
/// implementation with the real one in `lib/services/push_notifications.dart`
/// (that file's `init()` body is the full wiring: permission request,
/// token refresh, foreground handler, tap-to-open, cold start). Then:
///
///   final push = PushNotifications(
///     registerToken: (token) => ref.read(apiClientProvider)
///         .post('/user/push-token', body: {'token': token}),
///     onMessage: (_) {},                  // optional in-room banner
///     onOpenChat: (chatId) => openChat(chatId),
///   );
///   await push.init();
///
/// and keep a reference so `dispose()` runs on sign-out.
class PushController {
  PushController(this.openChat);

  /// Navigates to the chat room for [chatId] (uses the app's navigatorKey).
  final void Function(String chatId) openChat;

  bool _started = false;

  bool get isStarted => _started;

  Future<void> init() async {
    // [PUSH] real implementation from push_notifications.dart
    _started = true;
  }

  Future<void> dispose() async {
    // [PUSH] real implementation from push_notifications.dart
    _started = false;
  }
}

/// Opens [chatId] from a notification tap using the app-global navigator.
/// Safe no-op when the app isn't on a navigable route yet.
void openChatFromNotificationKey(GlobalKey<NavigatorState> navigatorKey, String chatId) {
  // [PUSH] push ChatRoomScreen(chat: ChatSummary(id: chatId, ...)) via
  // navigatorKey.currentState.
  navigatorKey.currentState?.pushNamed('/chat/$chatId');
}
