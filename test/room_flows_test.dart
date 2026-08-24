import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/screens/chat_room_screen.dart';
import 'package:chat_app/screens/create_room_screen.dart';
import 'package:chat_app/screens/join_room_screen.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

/// Host that pushes the screen under test so pop() works naturally.
class _Host extends StatelessWidget {
  const _Host({required this.screen});

  final Widget screen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => screen),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}

ProviderScope _app(MockClient mock, Widget screen) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
    ],
    child: MaterialApp(home: _Host(screen: screen)),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('CreateRoomScreen', () {
    testWidgets('creates a room with the entered name and access',
        (tester) async {
      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return _json({
          '_id': 'chat1',
          'name': 'My Room',
          'access': 'protected',
        }, 201);
      });

      await tester.pumpWidget(_app(mock, const CreateRoomScreen()));
      await _open(tester);

      await tester.enterText(find.byType(TextField), 'My Room');
      await tester.tap(find.text('Protected'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create room'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(captured?.method, 'POST');
      expect(captured?.url.path, '/api/chats');
      expect(jsonDecode(captured!.body), {
        'name': 'My Room',
        'participantIds': <String>[],
        'access': 'protected',
        'canSendMessages': 'everyone',
      });
    });

    testWidgets('requires a room name', (tester) async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        return _json({}, 201);
      });

      await tester.pumpWidget(_app(mock, const CreateRoomScreen()));
      await _open(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Create room'));
      await tester.pump();

      expect(calls, 0); // no request sent
      expect(find.text('Room name is required'), findsWidgets);
    });
  });

  group('JoinRoomScreen', () {
    testWidgets('searches and joins a public room', (tester) async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/chats/search') {
          expect(request.url.queryParameters['q'], 'team');
          return _json([
            {
              'chatId': 'c1',
              'name': 'Team Room',
              'access': 'public',
              'participantCount': 3,
            },
          ]);
        }
        return _json({'message': 'Joined chat successfully'}, 201);
      });

      await tester.pumpWidget(_app(mock, const JoinRoomScreen()));
      await _open(tester);

      await tester.enterText(find.byType(TextField), 'team');
      await tester.pump(const Duration(milliseconds: 500)); // debounce
      await tester.pump(); // search future

      expect(find.text('Team Room'), findsOneWidget);

      await tester.tap(find.text('Team Room'));
      await tester.pump(); // join + navigation start
      await tester.pump(const Duration(milliseconds: 300)); // route animation

      expect(paths, contains('/api/chats/c1/join'));
      expect(find.byType(ChatRoomScreen), findsOneWidget);
    });

    testWidgets('requests to join a protected room', (tester) async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/chats/search') {
          return _json([
            {
              'chatId': 'c2',
              'name': 'Secret Room',
              'access': 'protected',
              'participantCount': 7,
              'isRequested': false,
            },
          ]);
        }
        return _json({'status': 'pending', 'requestId': 'r1'}, 201);
      });

      await tester.pumpWidget(_app(mock, const JoinRoomScreen()));
      await _open(tester);

      await tester.enterText(find.byType(TextField), 'secret');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Secret Room'), findsOneWidget);

      await tester.tap(find.text('Request'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(paths, contains('/api/chats/c2/join-request'));
      expect(find.text('Requested'), findsOneWidget);
    });

    testWidgets('shows an empty hint before typing', (tester) async {
      final mock = MockClient((request) async => _json([]));
      await tester.pumpWidget(_app(mock, const JoinRoomScreen()));
      await _open(tester);

      expect(
        find.text('Type at least 2 characters to search.'),
        findsOneWidget,
      );
    });
  });
}
