import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ws_event.dart';
import '../providers/chat_list_provider.dart';
import '../providers/friends_providers.dart';
import '../utils/snack.dart';

/// Consumes `friend-*` and `join-request*` events from the `/ws/chat-list`
/// socket and surfaces them as snackbars, refreshing the relevant providers
/// so the UI reflects the change immediately.
///
/// Wraps [HomeShell] (via `AuthGate`), so notifications arrive on every tab.
/// The events intentionally leave `reduceChatList` untouched — this listener
/// is the only consumer.
class FriendNotificationListener extends ConsumerStatefulWidget {
  const FriendNotificationListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FriendNotificationListener> createState() =>
      _FriendNotificationListenerState();
}

class _FriendNotificationListenerState
    extends ConsumerState<FriendNotificationListener> {
  @override
  Widget build(BuildContext context) {
    // `ref.listen` (unlike `ref.watch`) must not be conditional; it's called
    // unconditionally on every build and Riverpod dedupes the subscription.
    ref.listen<AsyncValue<ChatListEvent>>(
      chatListEventsProvider,
      (prev, next) => next.whenData(_onEvent),
    );
    return widget.child;
  }

  void _onEvent(ChatListEvent event) {
    switch (event) {
      case ChatListFriendRequestEvent():
        showSnack(
          context,
          '${event.from.displayName} sent you a friend request',
        );
        ref.invalidate(friendRequestsProvider);
      case ChatListFriendRequestAcceptedEvent():
        showSnack(
          context,
          '${event.from.displayName} accepted your friend request',
        );
        ref.invalidate(friendsProvider);
        ref.invalidate(friendRequestsProvider);
      case ChatListFriendRequestCancelledEvent():
        // Silent: the sender withdrew their request — drop the incoming
        // tile without a notification.
        ref.invalidate(friendRequestsProvider);
      case ChatListFriendRequestDeclinedEvent():
        // Silent: the recipient said no — drop the outgoing tile without a
        // notification.
        ref.invalidate(friendRequestsProvider);
      case ChatListFriendRemovedEvent():
        final name = event.username ?? 'Someone';
        showSnack(context, '$name removed you as a friend');
        ref.invalidate(friendsProvider);
      case ChatListJoinRequestEvent():
        // Sent to the room's admins when someone asks to join. The event
        // carries no room name, so keep the copy generic; pending requests
        // are listed in the room details screen.
        final name = event.user?.displayName ?? 'Someone';
        showSnack(context, '$name asked to join one of your rooms');
      case ChatListJoinRequestUpdatedEvent():
        // Sent to the requester after an admin accepts/rejects.
        if (event.status == 'accepted') {
          showSnack(context, 'Your join request was approved');
          ref.invalidate(chatListProvider);
        } else {
          showSnack(context, 'Your join request was declined');
        }
      default:
        break;
    }
  }
}