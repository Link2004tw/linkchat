// Routes incoming chat-list WebSocket messages to local OS notifications on
// Linux desktop (FCM is unavailable there). See local_notifications.dart.
//
// Notification decision (pure function, unit-tested in
// test/local_notification_filter_test.dart):
//   - never notify about my own messages
//   - never notify about muted chats (self-mute = notifications-only flag)
//   - never notify while the app window is focused (you're already reading)
//   - otherwise notify


import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../models/ws_event.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_list_provider.dart';
import 'local_notifications.dart';

/// Tracks whether the app window is currently focused (resumed). A single
/// observer registered at startup; consulted by the notification router so
/// an open, focused app never buzzes about messages the user is already
/// reading.
class AppFocusTracker with WidgetsBindingObserver {
  bool _focused = true;

  /// True while the app window is in the foreground and interactive.
  bool get isFocused => _focused;

  /// Registers the observer globally. Call once from `main()` (after
  /// `WidgetsFlutterBinding.ensureInitialized`).
  void register() {
    WidgetsBinding.instance.addObserver(this);
    _focused =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _focused = state == AppLifecycleState.resumed;
  }
}

final appFocusTracker = AppFocusTracker();

/// Pure decision: should this new-message event become a local notification?
/// (Platform gating happens once at subscription time via [isLinuxTarget].)
///
/// [myClerkId] — signed-in user's Clerk id (null → nothing matches self).
/// [chatIsMuted] — the target chat's `mutedByUser` flag.
/// [appFocused] — whether the app window is currently resumed/focused.
bool shouldNotifyLocally({
  required String? myClerkId,
  required String? senderClerkId,
  required bool chatIsMuted,
  required bool appFocused,
}) {
  if (myClerkId != null && senderClerkId == myClerkId) return false;
  if (chatIsMuted) return false;
  if (appFocused) return false;
  return true;
}

/// Watches chat-list events and shows local notifications for incoming
/// messages on Linux. Watch this provider once from the app root; disposal
/// cancels the socket subscription automatically.
final localNotificationRouterProvider = Provider<void>((ref) {
  if (!isLinuxTarget) return;

  final socket = ref.watch(chatListSocketProvider);
  final sub = socket.events.listen((event) {
    // Only new-message events are interesting here.
    if (event is! ChatListNewMessageEvent) return;

    final me = ref.read(currentUserProvider)?.clerkId;
    final chats = ref.read(chatListProvider).valueOrNull ?? const [];
    ChatSummary? chat;
    for (final c in chats) {
      if (c.id == event.chatId) {
        chat = c;
        break;
      }
    }

    final author = event.lastMessage?.author;
    final senderId = author?.clerkId ?? author?.backendId;
    final should = shouldNotifyLocally(
      myClerkId: me,
      senderClerkId: senderId,
      chatIsMuted: chat?.mutedByUser ?? false,
      appFocused: appFocusTracker.isFocused,
    );
    if (!should) return;

    final title = chat?.displayName ?? author?.username ?? 'New message';
    final senderName = author?.username;
    final content = event.lastMessage?.content ?? '';
    final body = senderName == null || senderName.isEmpty
        ? content
        : '$senderName: $content';
    showMessageNotification(
      id: event.chatId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: event.chatId,
    );
  });
  ref.onDispose(sub.cancel);
});
