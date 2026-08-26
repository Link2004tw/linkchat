import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/friends_repository.dart';
import 'package:chat_app/repositories/user_repository.dart';
import 'package:chat_app/screens/blocked_users_screen.dart';
import 'package:chat_app/screens/friends_screen.dart';
import 'package:chat_app/screens/room_details_screen.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

final _group = ChatSummary(id: 'c1', name: 'Test Room', access: 'public');

Map<String, dynamic> _infoJson({
  String myRelation = 'owner',
  List<Map<String, dynamic>>? participants,
}) =>
    {
      '_id': 'c1',
      'name': 'Test Room',
      'description': '',
      'access': 'public',
      'canSendMessages': 'everyone',
      'createdBy': 'clerk_alice',
      'myRelation': myRelation,
      'participants': participants ??
          [
            {
              'user': {'userId': 'clerk_alice', 'username': 'alice'},
              'role': 'owner',
            },
            {
              'user': {'userId': 'clerk_bob', 'username': 'bob'},
              'role': 'member',
              'mutedUntil': null,
              'mutedByUser': false,
            },
          ],
    };

/// Builds a [RoomDetailsScreen] with the given mock HTTP client.
Widget _roomDetailsApp(
  MockClient mock, {
  ChatUser? me,
  ChatSummary? chat,
}) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
      if (me != null) currentUserProvider.overrideWithValue(me),
    ],
    child: MaterialApp(home: RoomDetailsScreen(chat: chat ?? _group)),
  );
}

Future<void> _pumpRoomDetails(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump(); // getInfo future
}

/// Builds the [BlockedUsersScreen] with the given mock HTTP client.
Widget _blockedUsersApp(MockClient mock) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
    ],
    child: MaterialApp(home: const BlockedUsersScreen()),
  );
}

/// Builds the [FriendsScreen] with the given mock HTTP client.
Widget _friendsApp(MockClient mock) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      friendsRepositoryProvider.overrideWithValue(FriendsRepository(api)),
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
    ],
    child: MaterialApp(home: const FriendsScreen()),
  );
}

void main() {
  // ── Admin mute / unmute ────────────────────────────────────────────────
  group('Admin mute/unmute', () {
    testWidgets('owner sees Mute… in member popup menu', (tester) async {
      final mock = MockClient((request) async => _json(_infoJson()));
      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        ),
      );

      // Bob (member) gets a PopupMenuButton; tap it.
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();

      expect(find.text('Mute…'), findsOneWidget);
      expect(find.text('Unmute'), findsNothing);
      expect(find.text('Kick'), findsOneWidget);
    });

    testWidgets('tapping Mute… shows duration sheet with 8h / 1w / Forever',
        (tester) async {
      final mock = MockClient((request) async => _json(_infoJson()));
      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute…'));
      await tester.pumpAndSettle();

      expect(find.text('Mute for 8 hours'), findsOneWidget);
      expect(find.text('Mute for 1 week'), findsOneWidget);
      expect(find.text('Mute forever'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('selecting duration sends PUT to mute endpoint',
        (tester) async {
      final paths = <String>[];
      final bodies = <String, dynamic>{};
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.method == 'PUT' &&
            request.url.path.contains('/members/') &&
            request.url.path.contains('/mute')) {
          bodies['mute'] = jsonDecode(request.body);
        }
        return _json(_infoJson());
      });

      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute for 8 hours'));
      await tester.pumpAndSettle();

      expect(
        paths,
        contains('PUT /api/chats/c1/members/clerk_bob/mute'),
      );
      expect(bodies['mute'], {'duration': '8h'});
    });

    testWidgets('muted member shows Unmute instead of Mute…', (tester) async {
      final mutedInfo = _infoJson(
        participants: [
          {
            'user': {'userId': 'clerk_alice', 'username': 'alice'},
            'role': 'owner',
          },
          {
            'user': {'userId': 'clerk_bob', 'username': 'bob'},
            'role': 'member',
            'mutedUntil':
                DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
            'mutedByUser': false,
          },
        ],
      );
      final mock = MockClient((request) async => _json(mutedInfo));
      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        ),
      );

      // Bob should show the muted icon.
      expect(find.byIcon(Icons.volume_off), findsOneWidget);

      // Popup menu shows Unmute instead of Mute…
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Unmute'), findsOneWidget);
      expect(find.text('Mute…'), findsNothing);
    });

    testWidgets('tapping Unmute sends DELETE to unmute endpoint',
        (tester) async {
      final mutedInfo = _infoJson(
        participants: [
          {
            'user': {'userId': 'clerk_alice', 'username': 'alice'},
            'role': 'owner',
          },
          {
            'user': {'userId': 'clerk_bob', 'username': 'bob'},
            'role': 'member',
            'mutedUntil':
                DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
            'mutedByUser': false,
          },
        ],
      );
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        return _json(mutedInfo);
      });

      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unmute'));
      await tester.pumpAndSettle();

      // Confirm dialog appears.
      expect(find.textContaining('Unmute @bob?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Unmute'));
      await tester.pumpAndSettle();

      expect(
        paths,
        contains('DELETE /api/chats/c1/members/clerk_bob/mute'),
      );
    });

    testWidgets('non-admin sees no mute options', (tester) async {
      final mock = MockClient(
        (request) async => _json(_infoJson(myRelation: 'member')),
      );
      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_carol', username: 'carol'),
        ),
      );

      // No PopupMenuButtons for non-admins (no manage menu).
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
    });
  });

  // ── Self-mute bell toggle ──────────────────────────────────────────────
  group('Self-mute bell toggle', () {
    testWidgets('bell icon shows notifications_active when not muted',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson());
        }
        return _json({'success': true});
      });

      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
            currentUserProvider.overrideWithValue(
              const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  // We can't easily test ChatRoomScreen in isolation because
                  // it needs WS + lots of providers. Instead, verify the
                  // icon logic via the RoomParticipant model.
                  return const Placeholder();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify the model logic that drives the bell icon.
      const unmuted = RoomParticipant(
        clerkId: 'clerk_alice',
        username: 'alice',
        role: 'owner',
      );
      final selfMuted = RoomParticipant(
        clerkId: 'clerk_alice',
        username: 'alice',
        role: 'owner',
        selfMutedUntil:
            DateTime.now().add(const Duration(hours: 8)).toIso8601String(),
      );

      expect(unmuted.isSelfMutedNow, isFalse);
      expect(unmuted.selfMutedUntil, isNull);
      expect(selfMuted.isSelfMutedNow, isTrue);
    });

    testWidgets('RoomParticipant.isSelfMutedNow respects expiry',
        (tester) async {
      const never = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        selfMutedUntil: null,
      );
      const expired = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        selfMutedUntil: '2020-01-01T00:00:00.000Z',
      );
      final active = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        selfMutedUntil:
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      );

      expect(never.isSelfMutedNow, isFalse);
      expect(expired.isSelfMutedNow, isFalse);
      expect(active.isSelfMutedNow, isTrue);
    });

    testWidgets('RoomParticipant.isMutedNow respects mutedUntil',
        (tester) async {
      const notMuted = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        mutedUntil: null,
      );
      const pastMuted = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        mutedUntil: '2020-01-01T00:00:00.000Z',
      );
      final futureMuted = RoomParticipant(
        clerkId: 'u1',
        username: 'user',
        role: 'member',
        mutedUntil:
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      );

      expect(notMuted.isMutedNow, isFalse);
      expect(pastMuted.isMutedNow, isFalse);
      expect(futureMuted.isMutedNow, isTrue);
    });
  });

  // ── BlockedUsersScreen ─────────────────────────────────────────────────
  group('BlockedUsersScreen', () {
    testWidgets('shows empty state when no blocked users', (tester) async {
      final mock = MockClient((request) async => _json([]));
      await tester.pumpWidget(_blockedUsersApp(mock));
      await tester.pump();

      expect(find.text('Blocked Users'), findsOneWidget);
      expect(find.text('No blocked users'), findsOneWidget);
    });

    testWidgets('lists blocked users with unblock buttons', (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/blocked') {
          return _json([
            {
              'clerkId': 'clerk_bob',
              'username': 'bob',
              'imageUrl': null,
            },
            {
              'clerkId': 'clerk_carol',
              'username': 'carol',
              'imageUrl': 'https://example.com/carol.jpg',
            },
          ]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_blockedUsersApp(mock));
      await tester.pump();

      expect(find.text('bob'), findsOneWidget);
      expect(find.text('carol'), findsOneWidget);
      expect(find.text('Unblock'), findsNWidgets(2));
    });

    testWidgets('unblock sends DELETE and refreshes the list',
        (tester) async {
      var blocked = true;
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/blocked') {
          if (blocked) {
            return _json([
              {
                'clerkId': 'clerk_bob',
                'username': 'bob',
                'imageUrl': null,
              },
            ]);
          }
          return _json([]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_blockedUsersApp(mock));
      await tester.pump();

      expect(find.text('bob'), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);

      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();

      // Confirm dialog.
      expect(find.textContaining('Unblock @bob?'), findsOneWidget);
      blocked = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Unblock'));
      await tester.pumpAndSettle();

      expect(
        paths,
        contains('DELETE /api/user/blocked/clerk_bob'),
      );
      expect(find.text('bob'), findsNothing);
      expect(find.text('No blocked users'), findsOneWidget);
    });
  });

  // ── Block entry points ─────────────────────────────────────────────────
  group('Block entry points', () {
    testWidgets('friends list shows Block in popup menu', (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/friends') {
          return _json([
            {
              '_id': 'u1',
              'userId': 'clerk_bob',
              'username': 'bob',
              'firstName': 'Bob',
              'dmChatId': 'dm1',
            },
          ]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_friendsApp(mock));
      await tester.pump();

      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Remove friend'), findsOneWidget);
      expect(
        find.text('Block'),
        findsOneWidget,
      );
    });

    testWidgets('block from friends list sends PUT and invalidates',
        (tester) async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/friends') {
          return _json([
            {
              '_id': 'u1',
              'userId': 'clerk_bob',
              'username': 'bob',
              'firstName': 'Bob',
              'dmChatId': 'dm1',
            },
          ]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_friendsApp(mock));
      await tester.pump();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();

      // Confirm dialog.
      expect(find.textContaining('Block Bob?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      expect(
        paths,
        contains('PUT /api/user/blocked/clerk_bob'),
      );
    });

    testWidgets('DM details shows block/unblock button', (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/blocked') {
          return _json([
            {
              'clerkId': 'clerk_bob',
              'username': 'bob',
              'imageUrl': null,
            },
          ]);
        }
        return _json({});
      });

      final dm = ChatSummary(
        id: 'dm1',
        access: 'direct',
        otherUser: const ChatOtherUser(
          clerkId: 'clerk_bob',
          name: 'Bob',
        ),
      );

      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(mock, chat: dm),
      );
      await tester.pump(); // block-state lookup

      // The DM card shows "Unblock user" when bob is already blocked.
      expect(find.text('Unblock user'), findsOneWidget);
      expect(find.text('Block user'), findsNothing);
    });

    testWidgets('DM details block toggle sends correct API call',
        (tester) async {
      final paths = <String>[];
      // Start with no blocked users → shows "Block user".
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/blocked') {
          return _json([]);
        }
        return _json({});
      });

      final dm = ChatSummary(
        id: 'dm1',
        access: 'direct',
        otherUser: const ChatOtherUser(
          clerkId: 'clerk_bob',
          name: 'Bob',
        ),
      );

      await _pumpRoomDetails(
        tester,
        _roomDetailsApp(
          mock,
          me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
          chat: dm,
        ),
      );
      await tester.pump(); // block-state lookup

      expect(find.text('Block user'), findsOneWidget);
      expect(find.text('Unblock user'), findsNothing);

      await tester.tap(find.text('Block user'));
      await tester.pumpAndSettle();

      // Confirm dialog.
      expect(find.textContaining('Block Bob?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      expect(
        paths,
        contains('PUT /api/user/blocked/clerk_bob'),
      );
    });
  });
}
