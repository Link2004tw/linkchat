import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/user_repository.dart';
import 'package:chat_app/screens/invite_screen.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

Widget _app(MockClient mock) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
    ],
    child: const MaterialApp(home: InviteScreen(chatId: 'c1')),
  );
}

Future<void> _search(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'bo');
  await tester.pump(const Duration(milliseconds: 500)); // debounce
  await tester.pump(); // search future
}

void main() {
  testWidgets('search shows results and inviting marks them invited',
      (tester) async {
    final paths = <String>[];
    final mock = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/user/search') {
        return _json([
          {
            'clerkId': 'clerk_bob',
            'name': 'Bob',
            'username': 'bob',
            'imageUrl': null,
            'friendRequestStatus': 'none',
          },
          {
            'clerkId': 'clerk_carol',
            'name': 'Carol',
            'username': 'carol',
            'imageUrl': null,
            'friendRequestStatus': 'none',
          },
        ]);
      }
      if (request.url.path == '/api/chats/c1/invite') {
        expect(jsonDecode(request.body), {'username': 'bob'});
        return _json({'success': true, 'message': 'Invited'}, 201);
      }
      return _json({'error': 'unexpected'}, 500);
    });

    await tester.pumpWidget(_app(mock));
    await _search(tester);

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    expect(paths, contains('/api/user/search'));

    await tester.tap(find.widgetWithText(FilledButton, 'Invite').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(paths, contains('/api/chats/c1/invite'));
    expect(find.text('Invited'), findsOneWidget); // Bob's row chip
    expect(find.text('Invited @bob'), findsOneWidget); // snackbar
    // Carol is still actionable — the screen stays open for more invites.
    expect(find.widgetWithText(FilledButton, 'Invite'), findsOneWidget);
  });

  testWidgets('already-in-room error surfaces a snackbar and keeps the button',
      (tester) async {
    final mock = MockClient((request) async {
      if (request.url.path == '/api/user/search') {
        return _json([
          {
            'clerkId': 'clerk_bob',
            'name': 'Bob',
            'username': 'bob',
            'imageUrl': null,
            'friendRequestStatus': 'none',
          },
        ]);
      }
      if (request.url.path == '/api/chats/c1/invite') {
        return _json({'message': 'User already in chat'}, 400);
      }
      return _json({'error': 'unexpected'}, 500);
    });

    await tester.pumpWidget(_app(mock));
    await _search(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Invite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Already in the room'), findsOneWidget);
    // Still actionable so the admin can invite other people.
    expect(find.widgetWithText(FilledButton, 'Invite'), findsOneWidget);
  });

  testWidgets('shows the empty hint before typing', (tester) async {
    final mock = MockClient((request) async => _json([]));
    await tester.pumpWidget(_app(mock));

    expect(
      find.text('Type at least 2 characters to search.'),
      findsOneWidget,
    );
  });
}
