import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/cache/chat_cache.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';

void main() {
  group('ChatCache', () {
    test('chat list round-trips', () async {
      final cache = ChatCache.memory;
      final chats = [
        ChatSummary(
          id: 'c1',
          name: 'Team',
          access: 'public',
          unreadCount: 2,
          lastMessage: const ChatLastMessage(content: 'hi', senderName: 'alice'),
        ),
        ChatSummary(
          id: 'dm1',
          access: 'direct',
          otherUser: const ChatOtherUser(clerkId: 'u1', name: 'Bob'),
        ),
      ];

      expect(cache.readChatList(), isNull); // nothing cached yet
      await cache.writeChatList(chats);

      final read = cache.readChatList();
      expect(read, isNotNull);
      expect(read, hasLength(2));
      expect(read![0].id, 'c1');
      expect(read[0].name, 'Team');
      expect(read[0].unreadCount, 2);
      expect(read[0].lastMessage?.content, 'hi');
      expect(read[0].lastMessage?.senderName, 'alice');
      expect(read[1].access, 'direct');
      expect(read[1].otherUser?.name, 'Bob');
    });

    test('room round-trips messages, cursor and hasMore', () async {
      final cache = ChatCache.memory;
      final messages = [
        ChatMessage(id: 'm1', content: 'a', contentType: 'text'),
        ChatMessage(id: 'm2', content: 'b', contentType: 'text'),
      ];

      expect(cache.readRoom('c1'), isNull);
      await cache.writeRoom('c1', messages: messages, cursor: 'm1', hasMore: true);

      final read = cache.readRoom('c1');
      expect(read, isNotNull);
      expect(read!.messages.map((m) => m.id), ['m1', 'm2']);
      expect(read.cursor, 'm1');
      expect(read.hasMore, isTrue);
    });

    test('room skips optimistic (pending) entries', () async {
      final cache = ChatCache.memory;
      final messages = [
        ChatMessage(id: 'm1', content: 'real', contentType: 'text'),
        ChatMessage(
          id: 'pending-c1-1',
          pendingId: 'pending-c1-1',
          content: 'optimistic',
          contentType: 'text',
        ),
      ];
      await cache.writeRoom('c1', messages: messages, cursor: null, hasMore: true);

      final read = cache.readRoom('c1');
      expect(read!.messages.map((m) => m.id), ['m1']);
    });

    test('clear wipes everything', () async {
      final cache = ChatCache.memory;
      await cache.writeChatList([
        ChatSummary(id: 'c1', name: 'x', access: 'public'),
      ]);
      await cache.writeRoom('c1', messages: [], cursor: null, hasMore: false);

      await cache.clear();
      expect(cache.isEmpty, isTrue);
      expect(cache.readChatList(), isNull);
      expect(cache.readRoom('c1'), isNull);
    });
  });

  group('ChatRoomController seeding', () {
    test('build seeds the room from the cache', () async {
      final cache = ChatCache.memory;
      await cache.writeRoom(
        'c1',
        messages: [ChatMessage(id: 'm1', content: 'cached', contentType: 'text')],
        cursor: 'm1',
        hasMore: true,
      );

      final container = ProviderContainer(
        overrides: [chatCacheProvider.overrideWithValue(cache)],
      );
      addTearDown(container.dispose);

      final state = container.read(chatRoomProvider('c1'));
      expect(state.messages.single.content, 'cached');
      expect(state.historyCursor, 'm1');
      expect(state.hasMoreHistory, isTrue);
      // Still loading — the socket's fresh history is the authority.
      expect(state.isLoading, isTrue);
    });

    test('state changes are persisted back to the cache', () async {
      final cache = ChatCache.memory;
      final container = ProviderContainer(
        overrides: [chatCacheProvider.overrideWithValue(cache)],
      );
      addTearDown(container.dispose);

      final controller = container.read(chatRoomProvider('c1').notifier);
      controller.sendText('hello'); // optimistic — persisted but skipped

      final stored = cache.readRoom('c1');
      expect(stored, isNotNull);
      expect(stored!.messages, isEmpty); // pending entries are not cached
    });
  });
}
