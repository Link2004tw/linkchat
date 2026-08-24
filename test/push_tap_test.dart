import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/app_navigator.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/friend_request.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/friends_providers.dart';
import 'package:chat_app/providers/push_provider.dart';
import 'package:chat_app/screens/chat_room_screen.dart';
import 'package:chat_app/screens/requests_screen.dart';

var requestsCalls = 0;

class _FakeChatListController extends ChatListController {
  _FakeChatListController(this._state);
  final AsyncValue<List<ChatSummary>> _state;
  @override
  AsyncValue<List<ChatSummary>> build() => _state;
}

class _FakeRoomController extends ChatRoomController {
  @override
  ChatRoomState build(String chatId) => ChatRoomState(
        messages: const [],
        isLoading: false,
        isConnected: true,
        hasMoreHistory: false,
      );
}

Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatListProvider.overrideWith(
          () => _FakeChatListController(AsyncValue.data(const [
            ChatSummary(id: 'c1', name: 'Room One', access: 'public'),
          ])),
        ),
        chatRoomProvider.overrideWith(_FakeRoomController.new),
        chatListEventsProvider.overrideWith((ref) => const Stream.empty()),
        currentUserProvider.overrideWithValue(null),
        friendsProvider.overrideWith((ref) async => const []),
        friendRequestsProvider.overrideWith((ref) async {
          requestsCalls++;
          return const FriendRequests();
        }),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        home: Consumer(
          builder: (context, ref, _) => Column(
            children: [
              TextButton(
                onPressed: () =>
                    ref.read(pushNotificationsProvider).onOpenRequests?.call(),
                child: const Text('open-requests'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(pushNotificationsProvider).onOpenChat('c1'),
                child: const Text('open-known-chat'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(pushNotificationsProvider).onOpenChat('nope'),
                child: const Text('open-unknown-chat'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    requestsCalls = 0;
  });

  testWidgets('friend-request tap opens the Requests screen with fresh data',
      (tester) async {
    await pumpApp(tester);

    expect(requestsCalls, 0); // nothing watches the provider on this screen
    await tester.tap(find.text('open-requests'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(RequestsScreen), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    // The tap invalidated the provider so the tile list is fetched fresh
    // for the newly opened screen.
    expect(requestsCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('chat tap with a known chat opens the chat room',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('open-known-chat'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ChatRoomScreen), findsOneWidget);
  });

  testWidgets('chat tap with an unknown chat does not navigate',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('open-unknown-chat'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ChatRoomScreen), findsNothing);
    expect(find.byType(RequestsScreen), findsNothing);
  });
}
