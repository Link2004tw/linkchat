import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/friends_repository.dart';
import 'package:chat_app/repositories/user_repository.dart';
import 'package:chat_app/screens/add_friends_screen.dart';
import 'package:chat_app/screens/chat_room_screen.dart';
import 'package:chat_app/screens/friends_screen.dart';
import 'package:chat_app/screens/requests_screen.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

ProviderScope _app(MockClient mock, Widget screen) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      friendsRepositoryProvider.overrideWithValue(FriendsRepository(api)),
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
    ],
    child: MaterialApp(home: screen),
  );
}

void main() {
  group('FriendsScreen', () {
    testWidgets('renders friends and opens the DM on tap', (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/friends') {
          return _json([
            {
              '_id': 'u1',
              'userId': 'clerk_a',
              'username': 'alice',
              'firstName': 'Alice',
              'profileImageUrl': null,
            },
            {
              '_id': 'u2',
              'userId': 'clerk_b',
              'username': 'bob',
              'firstName': 'Bob',
            },
          ]);
        }
        // Lazy DM resolution endpoint.
        if (request.url.path == '/api/user/friends/clerk_a/dm') {
          return _json({'dmChatId': 'dm1'});
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const FriendsScreen()));
      await tester.pump();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Alice'));
      await tester.pump(); // loading dialog appears
      await tester.pump(); // DM resolves, dialog dismissed, navigation starts
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ChatRoomScreen), findsOneWidget);
    });

    testWidgets('removes a friend after confirmation', (tester) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/friends') {
          return _json([
            {
              '_id': 'u1',
              'userId': 'clerk_a',
              'username': 'alice',
              'firstName': 'Alice',
              'dmChatId': 'dm1',
            },
          ]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const FriendsScreen()));
      await tester.pump();

      expect(find.text('Alice'), findsOneWidget);

      // Open the row's menu and pick Remove friend.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove friend'));
      await tester.pumpAndSettle();

      // Confirm dialog appears; cancelling sends nothing.
      expect(find.text('Remove friend?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.startsWith('DELETE')), isEmpty);

      // Removing sends the DELETE for this friend's clerk id.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove friend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(
        calls,
        contains('DELETE /api/user/friends/clerk_a'),
      );
    });
  });

  group('RequestsScreen', () {
    testWidgets('accepts an incoming request', (tester) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/friends/requests') {
          return _json({
            'ingoingRequests': [
              {
                '_id': 'fr1',
                'from': {
                  'userId': 'clerk_dave',
                  'username': 'dave',
                  'firstName': 'Dave',
                },
                'status': 'pending',
                'message': 'hi',
                'createdAt': '2025-01-01T10:00:00.000Z',
              },
            ],
            'outgoingRequests': <Object>[],
          });
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const RequestsScreen()));
      await tester.pump();

      expect(find.text('Dave'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains('PUT /api/user/friends/requests/fr1/accept'));
    });

    testWidgets('cancels an outgoing request', (tester) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/friends/requests') {
          return _json({
            'ingoingRequests': <Object>[],
            'outgoingRequests': [
              {
                '_id': 'fr2',
                'to': {
                  'userId': 'clerk_erin',
                  'username': 'erin',
                  'firstName': 'Erin',
                },
                'status': 'pending',
              },
            ],
          });
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const RequestsScreen()));
      await tester.pump();

      expect(find.text('Erin'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains('DELETE /api/user/friends/requests/fr2'));
    });

    testWidgets('accepted request tile disappears without a refetch',
        (tester) async {
      var accepted = false;
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/friends/requests') {
          if (accepted) {
            return _json({
              'ingoingRequests': <Object>[],
              'outgoingRequests': <Object>[],
            });
          }
          return _json({
            'ingoingRequests': [
              {
                '_id': 'fr3',
                'from': {
                  'userId': 'clerk_frank',
                  'username': 'frank',
                  'firstName': 'Frank',
                },
                'status': 'pending',
                'createdAt': '2025-01-01T10:00:00.000Z',
              },
            ],
            'outgoingRequests': <Object>[],
          });
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const RequestsScreen()));
      await tester.pump();
      expect(find.text('Frank'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      accepted = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The provider refetches after the accept and the request is gone.
      expect(find.text('Frank'), findsNothing);
      expect(find.text('No pending requests.'), findsOneWidget);
    });

    testWidgets('accepting also refreshes the chat list (DM appears)',
        (tester) async {
      var chatListCalls = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/friends/requests') {
          return _json({
            'ingoingRequests': [
              {
                '_id': 'fr4',
                'from': {
                  'userId': 'clerk_gary',
                  'username': 'gary',
                  'firstName': 'Gary',
                },
                'status': 'pending',
                'createdAt': '2025-01-01T10:00:00.000Z',
              },
            ],
            'outgoingRequests': <Object>[],
          });
        }
        if (request.url.path == '/api/chats/all') {
          chatListCalls++;
          return _json(<Object>[]);
        }
        return _json({'success': true});
      });

      final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            friendsRepositoryProvider.overrideWithValue(FriendsRepository(api)),
            userRepositoryProvider.overrideWithValue(UserRepository(api)),
            chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
          ],
          child: MaterialApp(
            home: Column(
              children: [
                const Expanded(child: RequestsScreen()),
                Consumer(
                  builder: (context, ref, _) {
                    ref.watch(chatListProvider);
                    return Text('chatlist:$chatListCalls');
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final initialCalls = chatListCalls;
      expect(initialCalls, greaterThan(0));
      expect(find.text('chatlist:$initialCalls'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Invalidation triggers a fresh chat-list fetch so the new DM shows.
      expect(chatListCalls, initialCalls + 1);
    });
  });

  group('AddFriendsScreen', () {
    testWidgets('sends then cancels a friend request', (tester) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/search') {
          return _json([
            {
              'clerkId': 'clerk_z',
              'name': 'Zed',
              'username': 'zed',
              'imageUrl': null,
              'friendRequestStatus': 'none',
              'friendRequestId': null,
            },
          ]);
        }
        if (request.url.path == '/api/user/friends' &&
            request.method == 'POST') {
          return _json({'success': true, 'requestId': 'fr9'}, 201);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const AddFriendsScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'zed');
      await tester.pump(const Duration(milliseconds: 500)); // debounce
      await tester.pump(); // search future

      expect(find.text('Zed'), findsOneWidget);

      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains('POST /api/user/friends'));
      expect(find.text('Cancel'), findsOneWidget); // flipped to pending

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains('DELETE /api/user/friends/requests/fr9'));
      expect(find.text('Add'), findsOneWidget); // back to none
    });

    testWidgets('accepts a received request from search results',
        (tester) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/user/search') {
          return _json([
            {
              'clerkId': 'clerk_y',
              'name': 'Yara',
              'username': 'yara',
              'imageUrl': null,
              'friendRequestStatus': 'respond',
              'friendRequestId': 'fr7',
            },
          ]);
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_app(mock, const AddFriendsScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'yara');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains('PUT /api/user/friends/requests/fr7/accept'));
      expect(find.text('Friends'), findsOneWidget); // now friends
    });
  });
}
