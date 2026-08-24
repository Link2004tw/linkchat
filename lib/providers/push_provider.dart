import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_navigator.dart';
import '../models/chat.dart';
import '../screens/chat_room_screen.dart';
import '../screens/requests_screen.dart';
import '../services/push_notifications.dart';
import 'auth_providers.dart';
import 'chat_list_provider.dart';
import 'friends_providers.dart';

/// Provides the PushNotifications controller that manages FCM token
/// registration, foreground message handling, and notification taps.
final pushNotificationsProvider = Provider<PushNotifications>((ref) {
  final apiClient = ref.watch(apiClientProvider);

  return PushNotifications(
    registerToken: (token) async {
      await apiClient.post('/user/push-token', body: {'token': token});
    },
    onMessage: (chatId) {
      // Optional: show an in-app banner when a message arrives while
      // the app is in the foreground.
    },
    onOpenChat: (chatId) {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      // Resolve the chat from the loaded list; a push for a chat we don't
      // know about (stale notification, list still loading) just opens the
      // app on whatever screen the user was on.
      ChatSummary? match;
      for (final chat in ref.read(chatListProvider).valueOrNull ?? const <ChatSummary>[]) {
        if (chat.id == chatId) {
          match = chat;
          break;
        }
      }
      if (match == null) return;
      // `pushNamed` is not usable — MaterialApp declares no route table, so
      // named routes throw. Push the screen directly instead.
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => ChatRoomScreen(chat: match!)),
      );
    },
    onOpenRequests: () {
      // Fresh data before the screen builds so the new tile is there.
      ref.invalidate(friendRequestsProvider);
      appNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(builder: (_) => const RequestsScreen()),
      );
    },
  );
});
