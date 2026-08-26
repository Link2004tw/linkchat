// Local desktop notifications (Linux).
//
// FCM doesn't exist on Linux, so while the app process is alive we show
// local notifications for incoming chat messages ourselves. The messages
// already arrive over the chat-list WebSocket; this service only renders
// them as OS notifications (see chat_list_notification_router for the
// filtering rules and wiring).
//
// Requires libnotify + a notification daemon on the host (most desktop
// environments ship one) — see RUN.md.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/app_navigator.dart';
import '../models/chat.dart';
import '../screens/chat_room_screen.dart';

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _initialized = false;

/// Whether local notifications are usable on this platform. Only true after
/// [initializeLocalNotificationsIfAvailable] succeeded on a supported OS.
bool get localNotificationsReady => _initialized;

/// Platform gate kept separate so callers/tests share one definition.
bool get isLinuxTarget => !Platform.isWindows && Platform.isLinux;

/// Initializes the plugin on Linux. No-op elsewhere (mobile uses FCM,
/// Windows/macOS can be added later with their respective settings).
Future<void> initializeLocalNotificationsIfAvailable() async {
  if (!isLinuxTarget) return;
  try {
    await _plugin.initialize(
      settings: const InitializationSettings(
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );
    _initialized = true;
  } catch (e) {
    // Notifications must never break the app.
    debugPrint('local notifications: INIT FAILED — disabled. Cause: $e');
  }
}

void _onTap(NotificationResponse response) {
  final chatId = response.payload;
  if (chatId == null || chatId.isEmpty) return;
  openChatFromPayload(chatId);
}

/// Opens the chat room for a tapped notification using the app-global
/// navigator. Safe no-op when no navigator is mounted yet.
void openChatFromPayload(String chatId) {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('local notifications: tap ignored — navigator not ready');
    return;
  }
  // Minimal summary: the room screen fetches real info on open.
  final chat = ChatSummary(id: chatId, access: 'public');
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => ChatRoomScreen(chat: chat)),
  );
}

/// Shows a message notification. [payload] should be the chat id so tapping
/// opens that room.
Future<void> showMessageNotification({
  required int id,
  required String title,
  required String body,
  String? payload,
}) async {
  if (!_initialized) return;
  try {
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        linux: LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.normal,
        ),
      ),
      payload: payload,
    );
  } catch (e) {
    debugPrint('local notifications: show failed — $e');
  }
}
