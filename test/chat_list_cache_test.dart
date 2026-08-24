import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/cache/chat_cache.dart';
import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

void main() {
  test('build seeds from the cache and then refreshes from REST', () async {
    final cache = ChatCache.memory;
    await cache.writeChatList([
      ChatSummary(id: 'c1', name: 'Cached', access: 'public'),
    ]);

    final mock = MockClient((request) async {
      expect(request.url.path, '/api/chats/all');
      return _json([
        {
          '_id': 'c2',
          'name': 'Fresh',
          'access': 'public',
          'unreadCount': 0,
          'updatedAt': '2025-01-01T10:00:00.000Z',
          'lastMessage': null,
          'participantCount': 1,
          'previewMembers': ['Alice'],
        },
      ]);
    });
    final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);

    final container = ProviderContainer(
      overrides: [
        chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
        chatCacheProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);

    // Reading the provider builds it synchronously: the cached list is
    // available immediately (offline launch), no spinner.
    final provider = container.read(chatListProvider);
    expect(provider.value?.single.id, 'c1');

    // The background refresh replaces it with the fresh REST list.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(chatListProvider).value?.single.id, 'c2');

    // And the fresh list was persisted back to the cache.
    expect(cache.readChatList()?.single.id, 'c2');
  });

  test('failed refresh keeps the cached list on screen', () async {
    final cache = ChatCache.memory;
    await cache.writeChatList([
      ChatSummary(id: 'c1', name: 'Cached', access: 'public'),
    ]);

    final mock = MockClient((request) async => http.Response('oops', 500));
    final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
    final container = ProviderContainer(
      overrides: [
        chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
        chatCacheProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(chatListProvider).value?.single.id, 'c1');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Still the cached list — the failure was swallowed.
    expect(container.read(chatListProvider).value?.single.id, 'c1');
  });
}
