import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/widgets/user_avatar.dart';

ChatMessage _text(String id, String content, {ChatUser? author}) => ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: author,
    );

void main() {
  group('applyChatEvent presence', () {
    test('online presence adds the user', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        const WsPresenceEvent(
          userId: 'u1',
          username: 'alice',
          isOnline: true,
        ),
      );
      expect(state.onlineUsers['u1']?.username, 'alice');
      expect(state.onlineUsers['u1']?.profileImageUrl, isNull);
    });

    test('avatar learned from messages survives the presence snapshot', () {
      // Presence broadcasts only carry userId + username; the avatar comes
      // from the user's messages. In practice messages arrive right after
      // the presence snapshot, so: message first, then presence.
      var state = applyChatEvent(
        const ChatRoomState(),
        WsMessageEvent(
          message: _text(
            'm1',
            'hello',
            author: const ChatUser(
              clerkId: 'u1',
              username: 'alice',
              profileImageUrl: 'https://example.com/alice.png',
            ),
          ),
        ),
      );
      // Avatar is remembered even before the user is online.
      expect(
        state.onlineUsers['u1']?.profileImageUrl,
        'https://example.com/alice.png',
      );

      // The presence broadcast for the same user must not lose it.
      state = applyChatEvent(
        state,
        const WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: true),
      );
      expect(
        state.onlineUsers['u1']?.profileImageUrl,
        'https://example.com/alice.png',
      );
      expect(state.onlineUsers['u1']?.username, 'alice');

      // And a later re-broadcast (e.g. another tab connecting) keeps it too.
      state = applyChatEvent(
        state,
        const WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: true),
      );
      expect(
        state.onlineUsers['u1']?.profileImageUrl,
        'https://example.com/alice.png',
      );
    });

    test('offline does not leak the avatar into the online list', () {
      var state = applyChatEvent(
        const ChatRoomState(),
        WsMessageEvent(
          message: _text(
            'm1',
            'hello',
            author: const ChatUser(
              clerkId: 'u1',
              username: 'alice',
              profileImageUrl: 'https://example.com/alice.png',
            ),
          ),
        ),
      );
      expect(state.onlineUsers.containsKey('u1'), isTrue);

      state = applyChatEvent(
        state,
        const WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: false),
      );
      expect(state.onlineUsers.containsKey('u1'), isFalse);
    });

    test('offline presence removes the user', () {
      final online = applyChatEvent(
        const ChatRoomState(),
        const WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: true),
      );
      final offline = applyChatEvent(
        online,
        const WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: false),
      );
      expect(offline.onlineUsers.containsKey('u1'), isFalse);
    });
  });

  group('UserAvatar', () {
    testWidgets('shows the initial when there is no image', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: UserAvatar(user: ChatUser(username: 'alice'))),
      ));
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('no status dot by default', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: UserAvatar(user: ChatUser(username: 'alice')),
        ),
      ));
      // The dot is a small colored Container in a Stack; without showStatusDot
      // there should be no green dot.
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == Colors.green),
        findsNothing,
      );
    });

    testWidgets('shows a green dot when online', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: UserAvatar(
            user: ChatUser(username: 'alice'),
            showStatusDot: true,
            isOnline: true,
          ),
        ),
      ));
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == Colors.green),
        findsOneWidget,
      );
    });
  });

}
