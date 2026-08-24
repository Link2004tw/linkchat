import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/screens/room_details_screen.dart';
import 'package:chat_app/repositories/user_repository.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

final _group = ChatSummary(id: 'c1', name: 'Backend Team', access: 'public');

final _dm = ChatSummary(
  id: 'dm1',
  access: 'direct',
  otherUser: const ChatOtherUser(
    clerkId: 'clerk_bob',
    name: 'Bob',
    imageUrl: null,
  ),
);

Map<String, dynamic> _infoJson() => {
  '_id': 'c1',
  'name': 'Backend Team',
  'description': 'A room for the backend team',
  'access': 'public',
  'canSendMessages': 'everyone',
  'createdBy': 'clerk_alice',
  'myRelation': 'owner',
  'participants': [
    {
      'user': {'userId': 'clerk_alice', 'username': 'alice'},
      'role': 'owner',
    },
    {
      'user': {'userId': 'clerk_bob', 'username': 'bob'},
      'role': 'admin',
    },
    {
      'user': {'userId': 'clerk_carol', 'username': 'carol'},
      'role': 'member',
    },
  ],
};

Widget _app(
  MockClient mock, {
  ChatUser? me,
  ChatSummary? chat,
  void Function(String)? onRenamed,
  Stream<ChatListEvent>? events,
}) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
      if (me != null) currentUserProvider.overrideWithValue(me),
      if (events != null) chatListEventsProvider.overrideWith((ref) => events),
    ],
    child: MaterialApp(
      home: RoomDetailsScreen(chat: chat ?? _group, onRenamed: onRenamed),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget app) async {
  // Tall surface so every ListView child is built (ListView is lazy —
  // off-screen tiles don't exist in the element tree for finders).
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump(); // getInfo future
}

void main() {
  testWidgets('renders the info block, participants and admin section', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      expect(request.url.path, '/api/chats/c1/info');
      return _json(_infoJson());
    });

    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ),
    );

    expect(find.text('Backend Team'), findsWidgets); // AppBar + info block
    expect(
      find.text('A room for the backend team'),
      findsOneWidget,
    ); // description
    expect(find.text('public'), findsOneWidget); // access badge
    expect(find.text('Everyone'), findsOneWidget); // can-send
    // Creator appears in the info block and as a participant row.
    expect(find.text('alice'), findsNWidgets(2));
    // 'owner' appears as "Your role" and as Alice's role badge.
    expect(find.text('owner'), findsNWidgets(2));
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('member'), findsOneWidget);
    expect(find.text('Rename room'), findsOneWidget); // admin section
    expect(find.text('Invite people'), findsOneWidget);
    expect(find.text('Leave room'), findsOneWidget);
    // Members header shows the live online count (nobody is online here).
    expect(find.text('0 online'), findsOneWidget);
  });

  testWidgets('members header online count updates live', (tester) async {
    final mock = MockClient((request) async => _json(_infoJson()));
    final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
          chatRoomProvider.overrideWith(() => ChatRoomController()),
          currentUserProvider.overrideWithValue(
            const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
          ),
        ],
        child: MaterialApp(home: RoomDetailsScreen(chat: _group)),
      ),
    );
    await tester.pump();

    expect(find.text('0 online'), findsOneWidget);

    // Bob comes online via the room presence state.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RoomDetailsScreen)),
    );
    container
        .read(chatRoomProvider('c1').notifier)
        .set(
          const ChatRoomState(
            onlineUsers: {
              'clerk_bob': ChatUser(clerkId: 'clerk_bob', username: 'bob'),
            },
          ),
        );
    await tester.pump();

    expect(find.text('1 online'), findsOneWidget);
  });

  testWidgets('rename dialog PUTs the name and reports it back', (
    tester,
  ) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/chats/c1/name') {
        expect(request.method, 'PUT');
        expect(jsonDecode(request.body), {'name': 'New Room'});
        return _json({
          'success': true,
          'chat': {'_id': 'c1', 'name': 'New Room'},
        });
      }
      if (request.url.path == '/api/chats/all') {
        // Chat-list refresh kicked off after the rename.
        return _json([
          {'_id': 'c1', 'name': 'New Room', 'access': 'public'},
        ]);
      }
      return _json(_infoJson());
    });
    String? renamed;
    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        onRenamed: (name) => renamed = name,
      ),
    );

    await tester.tap(find.text('Rename room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New Room');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(paths, contains('/api/chats/c1/name'));
    expect(renamed, 'New Room');
    // The rename also refreshes the chat list so the Chats tab shows the
    // new name without waiting for the room-update WS event.
    expect(paths, contains('/api/chats/all'));
  });

  testWidgets('rename dialog disables Rename while the name is empty', (
    tester,
  ) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      return _json(_infoJson());
    });
    await _pump(tester, _app(mock));

    await tester.tap(find.text('Rename room'));
    await tester.pumpAndSettle();

    final renameButton = find.widgetWithText(FilledButton, 'Rename');
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(renameButton).onPressed,
      isNull,
      reason: 'Rename must be disabled for an empty name',
    );

    await tester.enterText(find.byType(TextField), 'New Room');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(renameButton).onPressed, isNotNull);

    // No PUT is fired while the name is invalid.
    expect(paths.where((p) => p == '/api/chats/c1/name'), isEmpty);
  });

  testWidgets('description edit dialog PUTs the description and reloads', (
    tester,
  ) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/chats/c1/description') {
        expect(request.method, 'PUT');
        expect(jsonDecode(request.body), {'description': 'New room blurb'});
        return _json({
          'success': true,
          'chat': {'_id': 'c1'},
        });
      }
      if (request.url.path == '/api/chats/all') {
        return _json([
          {'_id': 'c1', 'name': 'Backend Team', 'access': 'public'},
        ]);
      }
      return _json(_infoJson());
    });
    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ),
    );

    await tester.tap(find.text('Room description'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New room blurb');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(paths, contains('/api/chats/c1/description'));
    expect(paths, contains('/api/chats/all')); // chat-list refresh
  });

  testWidgets('admin description tile shows the add/edit hint', (tester) async {
    final mock = MockClient((request) async {
      return _json({..._infoJson(), 'description': ''});
    });
    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ),
    );

    expect(find.text('Room description'), findsOneWidget); // admin tile
    expect(find.text('Add a description for this room'), findsOneWidget);
  });

  testWidgets('owner gets a manage menu per member; kick works from it', (
    tester,
  ) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/chats/c1/kick') {
        expect(jsonDecode(request.body), {'targettedUserId': 'clerk_bob'});
        return _json({'success': true});
      }
      return _json(_infoJson());
    });

    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ),
    );

    // Alice is the owner: she gets no menu; bob + carol each get one.
    expect(find.byIcon(Icons.more_vert), findsNWidgets(2));

    // First menu is bob's (admin) — kick him from it.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Kick'), findsOneWidget);
    await tester.tap(find.text('Kick'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kick @bob'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Kick'));
    await tester.pumpAndSettle();

    expect(paths, contains('/api/chats/c1/kick'));
  });

  testWidgets('owner can promote a member and demote an admin', (tester) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/chats/c1/members/clerk_carol/role') {
        expect(request.method, 'PUT');
        expect(jsonDecode(request.body), {'role': 'admin'});
        return _json({'success': true});
      }
      if (request.url.path == '/api/chats/c1/members/clerk_bob/role') {
        expect(request.method, 'PUT');
        expect(jsonDecode(request.body), {'role': 'member'});
        return _json({'success': true});
      }
      return _json(_infoJson());
    });

    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ),
    );

    // Carol (member) → "Make admin"; confirm posts the role.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Make admin'), findsOneWidget);
    await tester.tap(find.text('Make admin'));
    await tester.pumpAndSettle();
    expect(find.text('Make admin @carol?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Make admin'));
    await tester.pumpAndSettle();
    expect(paths, contains('/api/chats/c1/members/clerk_carol/role'));

    // Bob (admin) → "Remove admin"; confirm posts role=member.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Remove admin'), findsOneWidget);
    await tester.tap(find.text('Remove admin'));
    await tester.pumpAndSettle();
    expect(find.text('Remove admin @bob?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove admin'));
    await tester.pumpAndSettle();
    expect(paths, contains('/api/chats/c1/members/clerk_bob/role'));
  });

  testWidgets('non-admin sees no admin section and no kick buttons', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      return _json({..._infoJson(), 'myRelation': 'member'});
    });

    await _pump(
      tester,
      _app(
        mock,
        me: const ChatUser(clerkId: 'clerk_carol', username: 'carol'),
      ),
    );

    expect(find.text('Rename room'), findsNothing);
    expect(find.text('Room description'), findsNothing);
    expect(find.text('Invite people'), findsNothing);
    expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.text('Leave room'), findsOneWidget); // everyone can leave
  });

  testWidgets('refetches on room-update / membership events for this chat', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      final base = _infoJson();
      if (calls == 2) base['name'] = 'Renamed Live';
      return _json(base);
    });
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);

    await _pump(tester, _app(mock, events: controller.stream));
    expect(find.text('Backend Team'), findsNWidgets(2));
    expect(calls, 1);

    controller.add(
      const ChatListRoomUpdateEvent(
        chatId: 'c1',
        updates: {'name': 'Renamed Live'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Renamed Live'), findsNWidgets(2));
    expect(calls, 2);

    // A membership event (e.g. someone was invited) also refetches.
    controller.add(
      const ChatListMembershipEvent(type: 'invited', chatId: 'c1'),
    );
    await tester.pumpAndSettle();
    expect(calls, 3);
  });

  testWidgets('ignores events for other chats', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      return _json(_infoJson());
    });
    final controller = StreamController<ChatListEvent>.broadcast();
    addTearDown(controller.close);

    await _pump(tester, _app(mock, events: controller.stream));
    expect(calls, 1);

    controller.add(
      const ChatListRoomUpdateEvent(
        chatId: 'other-chat',
        updates: {'name': 'Someone Else'},
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1); // no refetch
    expect(find.text('Backend Team'), findsNWidgets(2));
  });

  testWidgets('DM shows the minimal other-user card and fetches no room info', (
    tester,
  ) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      return _json({});
    });

    await _pump(tester, _app(mock, chat: _dm));
  await tester.pump(); // block-state lookup (GET /user/blocked)

    expect(find.text('Bob'), findsNWidgets(2)); // AppBar + card
    expect(find.text('Direct message'), findsOneWidget);
    expect(find.text('Leave room'), findsNothing);
    // No /info call for DMs; only the block-state lookup (spec §14).
    expect(paths.where((p) => p == '/api/chats/c1/info'), isEmpty);
    expect(paths, contains('/api/user/blocked'));
  });

  testWidgets('info failure shows the error state and Retry recovers', (
    tester,
  ) async {
    var fail = true;
    final mock = MockClient((request) async {
      if (fail) return _json({'message': 'Forbidden'}, 403);
      return _json(_infoJson());
    });

    await _pump(tester, _app(mock));

    expect(find.textContaining('ApiException'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Backend Team'), findsWidgets);
    expect(find.text('Rename room'), findsOneWidget);
  });
}
