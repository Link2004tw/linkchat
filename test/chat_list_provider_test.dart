import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';

ChatSummary _chat(String id, {String? name, int unread = 0, DateTime? updatedAt}) =>
    ChatSummary(
      id: id,
      name: name,
      access: 'public',
      unreadCount: unread,
      updatedAt: updatedAt ?? DateTime.utc(2025, 1, 1),
    );

ChatListLastMessage _lastMessage(String content,
        {String? author, String? contentType, String? mediaUrl}) =>
    ChatListLastMessage(
      content: content,
      contentType: contentType ?? 'text',
      mediaUrl: mediaUrl,
      author: author == null ? null : ChatUser(username: author),
      createdAt: DateTime.utc(2025, 1, 2),
    );

void main() {
  group('reduceChatList', () {
    test('new-message updates the chat, bumps unread, moves it to top',
        () {
      // Both chats last updated Jan 1; the incoming message is dated Jan 2,
      // so c1 must surface above c2 after the event.
      final chats = [
        _chat('c1', name: 'Old', updatedAt: DateTime.utc(2025, 1, 1)),
        _chat('c2', name: 'New', updatedAt: DateTime.utc(2025, 1, 1)),
      ];

      final result = reduceChatList(chats, ChatListNewMessageEvent(
        chatId: 'c1',
        lastMessage: _lastMessage('hello', author: 'alice'),
        unreadCount: 2,
      ));

      expect(result, hasLength(2));
      expect(result.first.id, 'c1'); // moved to top
      expect(result.first.unreadCount, 2);
      expect(result.first.lastMessage?.content, 'hello');
      expect(result.first.lastMessage?.contentType, 'text');
      expect(result.first.lastMessage?.senderName, 'alice');
      expect(result[1].id, 'c2');
    });

    test('new-message carries the media URL through to the summary', () {
      final result = reduceChatList(
        [_chat('c1')],
        ChatListNewMessageEvent(
          chatId: 'c1',
          lastMessage: _lastMessage(
            '📷 Photo',
            contentType: 'image',
            mediaUrl: 'https://img/x.png',
          ),
          unreadCount: 1,
        ),
      );

      expect(result.single.lastMessage?.contentType, 'image');
      expect(result.single.lastMessage?.mediaUrl, 'https://img/x.png');
    });

    test('new-message for an unknown chat triggers onMissingChat', () {
      var called = false;
      final result = reduceChatList(
        [_chat('c1')],
        ChatListNewMessageEvent(
          chatId: 'c99',
          lastMessage: _lastMessage('hi'),
          unreadCount: 1,
        ),
        onMissingChat: () => called = true,
      );

      expect(called, isTrue);
      expect(result, hasLength(1));
    });

    test('unread-update sets the count', () {
      final result = reduceChatList(
        [_chat('c1', unread: 5)],
        ChatListUnreadUpdateEvent(chatId: 'c1', unreadCount: 0),
      );

      expect(result.single.unreadCount, 0);
    });

    test('room-update applies name and access', () {
      final result = reduceChatList(
        [_chat('c1', name: 'Old Name')],
        ChatListRoomUpdateEvent(chatId: 'c1', updates: {
          'name': 'New Name',
          'access': 'private',
        }),
      );

      expect(result.single.name, 'New Name');
      expect(result.single.access, 'private');
    });

    test('room-update for an unloaded chat triggers a refresh, not a drop', () {
      var refreshed = false;
      final result = reduceChatList(
        [_chat('c1')],
        ChatListRoomUpdateEvent(chatId: 'c9', updates: {'name': 'New Name'}),
        onMissingChat: () => refreshed = true,
      );

      expect(refreshed, isTrue);
      expect(result.map((c) => c.id), ['c1']);
    });

    test('room-update applies mutedByUser true and false', () {
      final muted = reduceChatList(
        [_chat('c1', name: 'Room')],
        ChatListRoomUpdateEvent(chatId: 'c1', updates: {'mutedByUser': true}),
      );
      expect(muted.single.mutedByUser, isTrue);

      final unmuted = reduceChatList(
        [muted.single],
        ChatListRoomUpdateEvent(chatId: 'c1', updates: {'mutedByUser': false}),
      );
      // Explicit false must reset the flag — mute-me broadcasts false.
      expect(unmuted.single.mutedByUser, isFalse);
    });

    test('room-update without mutedByUser keeps the current flag', () {
      final chat = _chat('c1', name: 'Room').copyWith(mutedByUser: true);
      final result = reduceChatList(
        [chat],
        ChatListRoomUpdateEvent(chatId: 'c1', updates: {'name': 'Renamed'}),
      );
      expect(result.single.mutedByUser, isTrue);
    });

    test('room-update ignores non-bool mutedByUser values', () {
      final result = reduceChatList(
        [_chat('c1', name: 'Room')],
        ChatListRoomUpdateEvent(
          chatId: 'c1',
          updates: {'mutedByUser': 'yes'},
        ),
      );
      expect(result.single.mutedByUser, isFalse);
    });

    test('kicked and leave-chat remove the chat', () {
      final chats = [_chat('c1'), _chat('c2')];

      final afterKick = reduceChatList(
        chats,
        ChatListMembershipEvent(type: 'kicked', chatId: 'c1'),
      );
      expect(afterKick.map((c) => c.id), ['c2']);

      final afterLeave = reduceChatList(
        chats,
        ChatListMembershipEvent(type: 'leave-chat', chatId: 'c2'),
      );
      expect(afterLeave.map((c) => c.id), ['c1']);
    });

    test('invited triggers a refresh', () {
      var called = false;
      reduceChatList(
        [_chat('c1')],
        ChatListMembershipEvent(type: 'invited', chatId: 'c9'),
        onMissingChat: () => called = true,
      );
      expect(called, isTrue);
    });

    test('unrelated events leave the list unchanged', () {
      final chats = [_chat('c1')];
      final result = reduceChatList(
        chats,
        ChatListConnectedEvent(message: 'hi'),
      );
      expect(identical(result, chats), isTrue);
    });

    test('friend-request and friend-request-accepted leave the list unchanged',
        () {
      final chats = [_chat('c1')];

      final afterRequest = reduceChatList(
        chats,
        ChatListFriendRequestEvent(
          requestId: 'req1',
          from: const ChatUser(username: 'alice'),
        ),
      );
      expect(identical(afterRequest, chats), isTrue);

      final afterAccept = reduceChatList(
        chats,
        ChatListFriendRequestAcceptedEvent(
          requestId: 'req1',
          from: const ChatUser(username: 'bob'),
        ),
      );
      expect(identical(afterAccept, chats), isTrue);
    });
  });

  group('ChatListSocket.sendMarkRead', () {
    test('queues when the socket is not connected', () {
      final socket = ChatListSocket(getToken: () async => null);
      addTearDown(socket.dispose);

      socket.sendMarkRead('c1');

      expect(socket.hasPendingMarkRead, isTrue);
    });

    test('a later mark-read replaces the queued chat', () {
      final socket = ChatListSocket(getToken: () async => null);
      addTearDown(socket.dispose);

      socket.sendMarkRead('c1');
      socket.sendMarkRead('c2');

      expect(socket.hasPendingMarkRead, isTrue);
    });

    test('no pending mark-read before any send', () {
      final socket = ChatListSocket(getToken: () async => null);
      addTearDown(socket.dispose);

      expect(socket.hasPendingMarkRead, isFalse);
    });
  });
}
