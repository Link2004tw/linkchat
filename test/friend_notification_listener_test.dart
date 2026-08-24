import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/friend.dart';
import 'package:chat_app/models/friend_request.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/friends_providers.dart';
import 'package:chat_app/widgets/friend_notification_listener.dart';

// Counts how many times each provider re-executed — watching them keeps the
// autoDispose providers alive so `ref.invalidate` triggers a refetch.
var friendsCalls = 0;
var requestsCalls = 0;

void main() {

  Future<void> pumpListener(
    WidgetTester tester,
    StreamController<ChatListEvent> controller,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatListEventsProvider.overrideWith((ref) => controller.stream),
          friendsProvider.overrideWith((ref) async {
            friendsCalls++;
            return const <Friend>[];
          }),
          friendRequestsProvider.overrideWith((ref) async {
            requestsCalls++;
            return const FriendRequests();
          }),
        ],
        child: MaterialApp(
          home: FriendNotificationListener(
            child: const Scaffold(body: Center(child: _ProviderCounters())),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    friendsCalls = 0;
    requestsCalls = 0;
  });

  testWidgets('friend-request shows a snackbar and refetches requests',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:0 requests:0'), findsNothing);
    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListFriendRequestEvent(
      requestId: 'req1',
      from: ChatUser(username: 'alice'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('alice sent you a friend request'), findsOneWidget);
    // Only the requests provider refetches — friends is untouched.
    expect(find.text('friends:1 requests:2'), findsOneWidget);
  });

  testWidgets('friend-request-accepted shows a snackbar and refetches both',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListFriendRequestAcceptedEvent(
      requestId: 'req1',
      from: ChatUser(username: 'bob'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('bob accepted your friend request'), findsOneWidget);
    expect(find.text('friends:2 requests:2'), findsOneWidget);
  });

  testWidgets('friend-removed shows a snackbar and refetches friends',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListFriendRemovedEvent(
      clerkId: 'clerk_remover',
      username: 'dave',
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('dave removed you as a friend'), findsOneWidget);
    // Only the friends provider refetches — requests is untouched.
    expect(find.text('friends:2 requests:1'), findsOneWidget);
  });

  testWidgets('friend-removed without a username falls back to Someone',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    controller.add(const ChatListFriendRemovedEvent(clerkId: 'clerk_remover'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Someone removed you as a friend'), findsOneWidget);
    expect(find.text('friends:2 requests:1'), findsOneWidget);
  });

  testWidgets('friend-request-cancelled silently refetches requests',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListFriendRequestCancelledEvent(
      requestId: 'req1',
      from: ChatUser(username: 'alice'),
    ));
    await tester.pump();
    await tester.pump();

    // Silent — no snackbar; only the requests provider refetches so the
    // incoming tile disappears.
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('friends:1 requests:2'), findsOneWidget);
  });

  testWidgets('friend-request-declined silently refetches requests',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListFriendRequestDeclinedEvent(
      requestId: 'req1',
      from: ChatUser(username: 'bob'),
    ));
    await tester.pump();
    await tester.pump();

    // Silent — no snackbar; only the requests provider refetches so the
    // outgoing tile disappears.
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('friends:1 requests:2'), findsOneWidget);
  });

  testWidgets('join-request shows a snackbar naming the requester',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    expect(find.text('friends:1 requests:1'), findsOneWidget);

    controller.add(const ChatListJoinRequestEvent(
      chatId: 'chat1',
      user: ChatUser(username: 'erin'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('erin asked to join one of your rooms'), findsOneWidget);
    // No provider refetch — room join requests are listed per-room.
    expect(find.text('friends:1 requests:1'), findsOneWidget);
  });

  testWidgets('join-request-updated approved refreshes the chat list',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    controller.add(const ChatListJoinRequestUpdatedEvent(
      chatId: 'chat1',
      status: 'accepted',
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Your join request was approved'), findsOneWidget);
  });

  testWidgets('join-request-updated rejected shows the declined snack',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    await pumpListener(tester, controller);

    controller.add(const ChatListJoinRequestUpdatedEvent(
      chatId: 'chat1',
      status: 'rejected',
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Your join request was declined'), findsOneWidget);
  });
}

class _ProviderCounters extends ConsumerWidget {
  const _ProviderCounters();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(friendsProvider);
    ref.watch(friendRequestsProvider);
    return Text('friends:$friendsCalls requests:$requestsCalls');
  }
}