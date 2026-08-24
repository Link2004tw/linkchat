import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

/// Regression tests for room renames reflecting automatically:
/// 1. The room AppBar updates from the live room-update WS event.
/// 2. Renaming in settings updates the open room's AppBar after popping
///    back (via `onRenamed`).

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

Map<String, dynamic> _infoJson(String name) => {
      '_id': 'c1',
      'name': name,
      'access': 'public',
      'canSendMessages': 'everyone',
      'createdBy': 'clerk_alice',
      'myRelation': 'owner',
      'participants': [
        {
          'user': {'userId': 'clerk_alice', 'username': 'alice'},
          'role': 'owner',
        },
      ],
    };

class _FakeRoomController extends ChatRoomController {
  _FakeRoomController(this._state);

  final ChatRoomState _state;

  @override
  ChatRoomState build(String chatId) => _state;
}

void main() {
  testWidgets('live room-update event updates the open room AppBar',
      (tester) async {
    final controller = StreamController<ChatListEvent>();
    addTearDown(controller.close);

    final room = ChatRoomState(
      messages: const [],
      isLoading: false,
      isConnected: true,
      hasMoreHistory: false,
    );

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatRoomProvider.overrideWith(() => _FakeRoomController(room)),
        chatListEventsProvider.overrideWith((ref) => controller.stream),
      ],
      child: const MaterialApp(
        home: ChatRoomScreen(
          chat: ChatSummary(id: 'c1', name: 'Old Room', access: 'public'),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Old Room'), findsOneWidget);

    // Another admin (or our own other device) renames the room; the
    // backend broadcasts room-update on the chat-list socket.
    controller.add(const ChatListRoomUpdateEvent(
      chatId: 'c1',
      updates: {'name': 'Renamed Live'},
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Renamed Live'), findsOneWidget);
  });

  testWidgets('rename from settings updates the room AppBar automatically',
      (tester) async {
    final calls = <String>[];
    final mock = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/chats/c1/name' &&
          request.method == 'PUT') {
        return _json({
          'success': true,
          'chat': {'_id': 'c1', 'name': 'New Name'},
        });
      }
      if (request.url.path == '/api/chats/c1/info') {
        return _json(_infoJson('New Name'));
      }
      return _json({'success': true});
    });
    final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);

    final room = ChatRoomState(
      messages: const [],
      isLoading: false,
      isConnected: true,
      hasMoreHistory: false,
    );

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatRoomProvider.overrideWith(() => _FakeRoomController(room)),
        chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
        chatListEventsProvider.overrideWith((ref) => const Stream.empty()),
      ],
      child: MaterialApp(
        home: ChatRoomScreen(
          chat: const ChatSummary(id: 'c1', name: 'Old Room', access: 'public'),
        ),
      ),
    ));
    await tester.pump();

    // AppBar starts with the old name.
    expect(find.text('Old Room'), findsOneWidget);

    // Open settings → rename.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New Name');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(calls, contains('PUT /api/chats/c1/name'));

    // Pop back to the room — the AppBar should show the new name.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('New Name'), findsOneWidget);
  });
}
