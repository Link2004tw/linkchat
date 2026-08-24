import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

Widget _app(Stream<ChatListEvent> events, ChatSummary chat) => ProviderScope(
      overrides: [
        chatListEventsProvider.overrideWith((ref) => events),
      ],
      child: MaterialApp(home: ChatRoomScreen(chat: chat)),
    );

void main() {
  testWidgets('AppBar reflects access and can-send changes via room-update',
      (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    final chat = ChatSummary(id: 'c1', name: 'Backend Team', access: 'public');

    await tester.pumpWidget(_app(controller.stream, chat));
    await tester.pump();

    // Search + room settings are reachable via visible AppBar icons.
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.byTooltip('Room settings'), findsOneWidget);

    // Initial: quiet "connecting…" (not a retry notice) + access, no
    // can-send note. The retry message only appears after a genuine drop.
    expect(find.textContaining('connecting'), findsOneWidget);
    expect(find.textContaining('reconnecting'), findsNothing);
    expect(find.textContaining('public'), findsOneWidget);
    expect(find.textContaining('admins only'), findsNothing);

    controller.add(const ChatListRoomUpdateEvent(
      chatId: 'c1',
      updates: {'access': 'protected', 'canSendMessages': 'admins'},
    ));
    await tester.pump();

    expect(find.textContaining('protected'), findsOneWidget);
    expect(find.textContaining('admins only'), findsOneWidget);
    expect(find.textContaining('public'), findsNothing);

    // A later update can flip it back and rename the room.
    controller.add(const ChatListRoomUpdateEvent(
      chatId: 'c1',
      updates: {
        'name': 'Renamed Room',
        'access': 'private',
        'canSendMessages': 'everyone',
      },
    ));
    await tester.pump();

    expect(find.text('Renamed Room'), findsOneWidget);
    expect(find.textContaining('private'), findsOneWidget);
    expect(find.textContaining('admins only'), findsNothing);
  });

  testWidgets('room-update for another chat is ignored', (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    final chat = ChatSummary(id: 'c1', name: 'Backend Team', access: 'public');

    await tester.pumpWidget(_app(controller.stream, chat));
    await tester.pump();

    controller.add(const ChatListRoomUpdateEvent(
      chatId: 'other-chat',
      updates: {'name': 'Someone Else', 'access': 'private'},
    ));
    await tester.pump();

    expect(find.text('Backend Team'), findsOneWidget);
    expect(find.textContaining('public'), findsOneWidget);
  });

  testWidgets('DM AppBar keeps just the online count', (tester) async {
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);
    final chat = ChatSummary(
      id: 'dm1',
      access: 'direct',
      otherUser: const ChatOtherUser(clerkId: 'clerk_bob', name: 'Bob'),
    );

    await tester.pumpWidget(_app(controller.stream, chat));
    await tester.pump();

    expect(find.textContaining('connecting'), findsOneWidget);
    expect(find.textContaining('reconnecting'), findsNothing);
    expect(find.textContaining('direct'), findsNothing); // no access shown for DMs

    // DMs keep message search but hide the room-settings gear (mirrors the
    // web app, where settings only exists for non-DM rooms).
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);

    controller.add(const ChatListRoomUpdateEvent(
      chatId: 'dm1',
      updates: {'access': 'private'},
    ));
    await tester.pump();

    expect(find.textContaining('direct'), findsNothing);
  });
}
