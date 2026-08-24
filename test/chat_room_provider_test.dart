import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';

ChatMessage _text(String id, String content) => ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
    );

WsMessageEvent _msg(String id, String content) =>
    WsMessageEvent(message: _text(id, content));

void main() {
  group('applyChatEvent', () {
    test('message event appends', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        _msg('m1', 'hello'),
      );
      expect(state.messages, hasLength(1));
      expect(state.messages.single.content, 'hello');
    });

    test('duplicate message id is replaced, not duplicated', () {
      final once = applyChatEvent(const ChatRoomState(), _msg('m1', 'a'));
      final twice = applyChatEvent(once, _msg('m1', 'b'));
      expect(twice.messages, hasLength(1));
      expect(twice.messages.single.content, 'b');
    });

    test('room-update system message dedupes against its history replay', () {
      // A room update is persisted AND broadcast live as a `type: "message"`
      // frame carrying the real id. On reconnect the same row is replayed in
      // history — the shared id must yield one row, never two ("… updated the
      // room" appearing twice).
      ChatMessage system(String id) => ChatMessage(
            id: id,
            content: 'alice updated the room',
            contentType: 'system',
            event: 'room-update',
          );
      final live =
          applyChatEvent(const ChatRoomState(), WsMessageEvent(message: system('sys-1')));
      final afterReconnect =
          applyChatEvent(live, WsMessageEvent(message: system('sys-1')));
      expect(afterReconnect.messages, hasLength(1));
      expect(afterReconnect.messages.single.id, 'sys-1');
    });

    test('edit replaces content and marks isEdited', () {
      final state = applyChatEvent(
        applyChatEvent(const ChatRoomState(), _msg('m1', 'original')),
        WsEditEvent(messageId: 'm1', content: 'edited'),
      );
      expect(state.messages.single.content, 'edited');
      expect(state.messages.single.isEdited, isTrue);
    });

    test('delete removes the message', () {
      final state = applyChatEvent(
        applyChatEvent(
          applyChatEvent(const ChatRoomState(), _msg('m1', 'a')),
          _msg('m2', 'b'),
        ),
        WsDeleteEvent(messageId: 'm1'),
      );
      expect(state.messages.map((m) => m.id), ['m2']);
    });

    test('presence adds online and removes offline users', () {
      final online = applyChatEvent(
        const ChatRoomState(),
        WsPresenceEvent(
          userId: 'u1',
          username: 'alice',
          isOnline: true,
        ),
      );
      expect(online.onlineUsers['u1']?.username, 'alice');

      final offline = applyChatEvent(
        online,
        WsPresenceEvent(userId: 'u1', username: 'alice', isOnline: false),
      );
      expect(offline.onlineUsers.containsKey('u1'), isFalse);
    });

    test('welcome system message marks history complete', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(state.isLoading, isFalse);
      expect(state.isConnected, isTrue);
      // The welcome marker is not rendered as a chat row (it fires on every
      // reconnect, so it would otherwise spam the thread).
      expect(state.messages, isEmpty);
    });

    test('welcome after a short history batch disables load-older', () {
      // The server replays at most 50 messages on connect; a batch that came
      // back short means there is no older history to page into.
      var state = const ChatRoomState();
      for (var i = 0; i < 5; i++) {
        state = applyChatEvent(state, _msg('m$i', 'hi $i'));
      }
      state = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(state.hasMoreHistory, isFalse);
    });

    test('welcome after a full-cap batch keeps load-older available', () {
      var state = const ChatRoomState();
      for (var i = 0; i < 50; i++) {
        state = applyChatEvent(state, _msg('m$i', 'hi $i'));
      }
      state = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(state.hasMoreHistory, isTrue);
    });

    test('welcome never re-enables load-older after pagination confirmed end',
        () {
      var state = const ChatRoomState(hasMoreHistory: false);
      for (var i = 0; i < 60; i++) {
        state = applyChatEvent(state, _msg('m$i', 'hi $i'));
      }
      // Reconnect replays the last 50, but the user already paged to the end.
      state = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(state.hasMoreHistory, isFalse);
    });

    test('join system message adds a row but keeps loading', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        WsSystemEvent(type: 'join', text: 'alice joined the chat'),
      );
      expect(state.isLoading, isTrue);
      expect(state.messages.single.event, 'join');
    });

    test('typing adds the user id', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        WsTypingEvent(userId: 'u1', username: 'alice'),
      );
      expect(state.typingUserIds, contains('u1'));
    });

    test('error sets lastError', () {
      final state = applyChatEvent(
        const ChatRoomState(),
        WsErrorEvent(text: 'boom'),
      );
      expect(state.lastError, 'boom');
    });

    test('clearError/clearUploadError reset the transient errors', () {
      const state = ChatRoomState(lastError: 'boom', uploadError: 'nope');
      final next = state.copyWith(clearError: true, clearUploadError: true);
      expect(next.lastError, isNull);
      expect(next.uploadError, isNull);
    });
  });
}
