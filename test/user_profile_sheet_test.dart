import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/user_repository.dart';
import 'package:chat_app/widgets/chat/user_profile_sheet.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

Map<String, dynamic> _profileJson({
  String status = 'none',
}) =>
    {
      'clerkId': 'clerk_bob',
      'username': 'bob',
      'name': 'Bob',
      // No imageUrl — the test env can't fetch NetworkImages.
      'friendRequestStatus': status,
      'sharedRoomsCount': 2,
    };

Widget _sheetApp(
  MockClient mock, {
  String? meClerkId,
  String clerkId = 'clerk_bob',
}) {
  final api = ApiClient(getToken: () async => 'jwt', httpClient: mock);
  return ProviderScope(
    overrides: [
      userRepositoryProvider.overrideWithValue(UserRepository(api)),
      if (meClerkId != null)
        currentUserProvider.overrideWithValue(
          ChatUser(clerkId: meClerkId, username: 'me'),
        ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: FilledButton(
              onPressed: () => showUserProfileSheet(
                context,
                ref,
                clerkId: clerkId,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.tap(find.text('open'));
  await tester.pump(); // start sheet animation
  await tester.pump(const Duration(milliseconds: 300)); // settle sheet
  await tester.pump(); // flush profile futures
  await tester.pump();
}

void main() {
  group('UserRepository.getUser', () {
    test('parses GET /user/:clerkId', () async {
      String? path;
      final mock = MockClient((request) async {
        path = '${request.method} ${request.url.path}';
        return _json(_profileJson());
      });
      final repo = UserRepository(
        ApiClient(getToken: () async => 'jwt', httpClient: mock),
      );

      final result = await repo.getUser('clerk_bob');

      expect(path, 'GET /api/user/clerk_bob');
      expect(result.user.username, 'bob');
      expect(result.user.clerkId, 'clerk_bob');
      expect(result.friendRequestStatus, 'none');
      expect(result.sharedRoomsCount, 2);
    });

    test('surfaces 404 (target blocked caller)', () async {
      final mock = MockClient((request) async => _json({
            'error': 'Not found',
          }, 404));
      final repo = UserRepository(
        ApiClient(getToken: () async => 'jwt', httpClient: mock),
      );

      await expectLater(repo.getUser('clerk_x'), throwsException);
    });
  });

  group('user profile sheet', () {
    testWidgets('shows spinner while loading, then profile info',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/clerk_bob') {
          return _json(_profileJson());
        }
        if (request.url.path == '/api/user/blocked') return _json([]);
        return _json({});
      });

      await _open(tester, _sheetApp(mock));

      // Header rendered from fetched profile.
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('2 shared rooms'), findsOneWidget);
      // Status "none" → Add friend.
      expect(find.text('Add friend'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('friend status shows Message / Remove / Block',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/clerk_bob') {
          return _json(_profileJson(status: 'friends'));
        }
        if (request.url.path == '/api/user/blocked') return _json([]);
        return _json({});
      });

      await _open(tester, _sheetApp(mock));

      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Remove friend'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(find.text('Add friend'), findsNothing);
    });

    testWidgets('own profile hides all actions and skips the fetch',
        (tester) async {
      var fetchedProfile = false;
      final mock = MockClient((request) async {
        if (request.url.path.contains('/api/user/me_clerk')) {
          fetchedProfile = true;
          return _json(_profileJson());
        }
        if (request.url.path == '/api/user/blocked') return _json([]);
        return _json({});
      });

      await _open(
        tester,
        _sheetApp(mock, meClerkId: 'me_clerk', clerkId: 'me_clerk'),
      );

      expect(fetchedProfile, isFalse);
      expect(find.text('Add friend'), findsNothing);
      expect(find.text('Block'), findsNothing);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('404 (blocked caller) shows unavailable message',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/user/clerk_bob') {
          return _json({'error': 'Not found'}, 404);
        }
        return _json({});
      });

      await _open(tester, _sheetApp(mock));

      expect(find.text('Profile unavailable'), findsOneWidget);
      expect(find.text('Add friend'), findsNothing);
    });
  });
}
