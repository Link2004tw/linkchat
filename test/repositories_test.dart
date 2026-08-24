import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/dictionary_repository.dart';
import 'package:chat_app/repositories/friends_repository.dart';
import 'package:chat_app/repositories/messages_repository.dart';
import 'package:chat_app/repositories/user_repository.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api(MockClient mock) =>
    ApiClient(getToken: () async => 'test-jwt', httpClient: mock);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

void main() {
  group('ChatsRepository', () {
    test('getAll parses group and DM chats', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/chats/all');
        expect(request.headers['Authorization'], 'Bearer test-jwt');
        return _json([
          {
            '_id': 'c1',
            'name': 'Backend Team',
            'access': 'public',
            'unreadCount': 3,
            'updatedAt': '2025-01-01T10:00:00.000Z',
            'lastMessage': {
              'content': 'ship it',
              'sentAt': '2025-01-01T09:59:00.000Z',
              'senderId': 'alice',
            },
            'participantCount': 5,
            'previewMembers': ['alice', 'bob'],
          },
          {
            '_id': 'c2',
            'access': 'direct',
            'unreadCount': 0,
            'updatedAt': '2025-01-01T10:00:00.000Z',
            'otherUser': {
              'clerkId': 'clerk_bob',
              'name': 'Bob',
              'imageUrl': 'https://img/b.png',
            },
          },
        ]);
      });

      final chats = await ChatsRepository(_api(mock)).getAll();
      expect(chats, hasLength(2));
      expect(chats[0].displayName, 'Backend Team');
      expect(chats[0].lastMessage?.senderName, 'alice');
      expect(chats[1].isDm, isTrue);
      expect(chats[1].displayName, 'Bob');
    });

    test('search sends the query param and parses results', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/chats/search');
        expect(request.url.queryParameters['q'], 'team');
        return _json([
          {
            'chatId': 'c3',
            'name': 'Team X',
            'access': 'protected',
            'participantCount': 4,
            'isRequested': true,
          },
        ]);
      });

      final results = await ChatsRepository(_api(mock)).search('team');
      expect(results.single.name, 'Team X');
      expect(results.single.access, 'protected');
      expect(results.single.isRequested, isTrue);
    });

    test('startDm posts the userId and returns the chatId', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/dm/start');
        expect(jsonDecode(request.body), {'userId': 'clerk_bob'});
        return _json({'chatId': 'dm1', 'isNew': true}, 201);
      });

      final chatId = await ChatsRepository(_api(mock)).startDm('clerk_bob');
      expect(chatId, 'dm1');
    });

    test('join hits the join endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/c1/join');
        return _json({'message': 'Joined chat successfully'}, 201);
      });

      await ChatsRepository(_api(mock)).join('c1');
    });

    test('getInfo parses participants, roles and myRelation', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/chats/c1/info');
        return _json({
          '_id': 'c1',
          'name': 'Backend Team',
          'access': 'public',
          'canSendMessages': 'everyone',
          'createdBy': 'clerk_alice',
          'inviteCode': 'ABC123',
          'myRelation': 'admin',
          'participants': [
            {
              'user': {
                '_id': 'clerk_alice',
                'userId': 'clerk_alice',
                'username': 'alice',
                'profileImageUrl': 'https://img/a.png',
              },
              'role': 'owner',
            },
            {
              'user': {
                '_id': 'clerk_bob',
                'userId': 'clerk_bob',
                'username': 'bob',
                'profileImageUrl': '',
              },
              'role': 'member',
            },
          ],
        });
      });

      final info = await ChatsRepository(_api(mock)).getInfo('c1');
      expect(info.id, 'c1');
      expect(info.name, 'Backend Team');
      expect(info.inviteCode, 'ABC123');
      expect(info.myRelation, 'admin');
      expect(info.isAdmin, isTrue);
      expect(info.participants, hasLength(2));
      expect(info.participants.first.clerkId, 'clerk_alice');
      expect(info.participants.first.role, 'owner');
      expect(info.participants.first.isAdmin, isTrue);
      expect(info.participants[1].username, 'bob');
      expect(info.participants[1].isAdmin, isFalse);
    });

    test('invite posts the username', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/c1/invite');
        expect(jsonDecode(request.body), {'username': 'carol'});
        return _json({'success': true, 'message': 'Invited'}, 201);
      });

      await ChatsRepository(_api(mock)).invite('c1', 'carol');
    });

    test('kick posts the backend-misspelled targettedUserId', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/c1/kick');
        expect(jsonDecode(request.body),
            {'targettedUserId': 'clerk_bob'});
        return _json({'success': true});
      });

      await ChatsRepository(_api(mock)).kick('c1', 'clerk_bob');
    });

    test('rename puts the name and returns the echoed name', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/chats/c1/name');
        expect(jsonDecode(request.body), {'name': 'New Name'});
        return _json({'success': true, 'chat': {'_id': 'c1', 'name': 'New Name'}});
      });

      final name = await ChatsRepository(_api(mock)).rename('c1', 'New Name');
      expect(name, 'New Name');
    });

    test('updateAccess puts access with an optional inviteCode', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/chats/c1/access');
        expect(jsonDecode(request.body), {'access': 'protected', 'inviteCode': 'XYZ'});
        return _json({'success': true});
      });

      await ChatsRepository(_api(mock))
          .updateAccess('c1', 'protected', inviteCode: 'XYZ');
    });

    test('updateAccess omits inviteCode when not provided', () async {
      final mock = MockClient((request) async {
        expect(jsonDecode(request.body), {'access': 'private'});
        return _json({'success': true});
      });

      await ChatsRepository(_api(mock)).updateAccess('c1', 'private');
    });

    test('updateCanSendMessage puts the policy', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/chats/c1/canSendMessage');
        expect(jsonDecode(request.body), {'canSendMessages': 'admins'});
        return _json({'success': true});
      });

      await ChatsRepository(_api(mock)).updateCanSendMessage('c1', 'admins');
    });

    test('setRole puts the role to the member endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/chats/c1/members/clerk_bob/role');
        expect(jsonDecode(request.body), {'role': 'admin'});
        return _json({'success': true});
      });

      await ChatsRepository(_api(mock)).setRole('c1', 'clerk_bob', 'admin');
    });
  });

  group('MessagesRepository', () {
    test('getMessages parses the page and forwards the before cursor',
        () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/chats/c1/messages');
        expect(request.url.queryParameters['limit'], '30');
        expect(request.url.queryParameters['before'], 'm10');
        return _json({
          'messages': [
            {'_id': 'm9', 'content': 'a', 'author': {'username': 'alice'}},
            {'_id': 'm10', 'content': 'b', 'author': {'username': 'bob'}},
          ],
          'name': 'General',
          'more': true,
          'nextCursor': 'm9',
          'canSendMessages': 'everyone',
          'isDm': false,
        });
      });

      final page = await MessagesRepository(_api(mock))
          .getMessages('c1', limit: 30, before: 'm10');
      expect(page.messages, hasLength(2));
      expect(page.nextCursor, 'm9');
      expect(page.more, isTrue);
      expect(page.canSendMessages, 'everyone');
    });

    test('deleteForMe posts to the delete-for-me endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/c1/messages/m9/delete-for-me');
        return _json({'success': true});
      });

      await MessagesRepository(_api(mock)).deleteForMe('c1', 'm9');
    });
  });

  group('FriendsRepository', () {
    test('getFriends parses dmChatId', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/user/friends');
        return _json([
          {
            '_id': 'u1',
            'userId': 'clerk_a',
            'username': 'alice',
            'firstName': 'Alice',
            'profileImageUrl': 'https://img/a.png',
            'dmChatId': 'dm1',
          },
        ]);
      });

      final friends = await FriendsRepository(_api(mock)).getFriends();
      expect(friends.single.dmChatId, 'dm1');
      expect(friends.single.displayName, 'Alice');
    });

    test('sendRequest posts targetClerkId and returns the requestId',
        () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/user/friends');
        expect(jsonDecode(request.body), {'targetClerkId': 'clerk_b'});
        return _json({'success': true, 'requestId': 'fr1'}, 201);
      });

      expect(
        await FriendsRepository(_api(mock)).sendRequest('clerk_b'),
        'fr1',
      );
    });

    test('accept/decline/cancel/remove hit the right verbs and paths',
        () async {
      String? last;
      final mock = MockClient((request) async {
        last = '${request.method} ${request.url.path}';
        return _json({'success': true});
      });

      final repo = FriendsRepository(_api(mock));
      await repo.acceptRequest('fr1');
      expect(last, 'PUT /api/user/friends/requests/fr1/accept');
      await repo.declineRequest('fr2');
      expect(last, 'PUT /api/user/friends/requests/fr2/decline');
      await repo.cancelRequest('fr3');
      expect(last, 'DELETE /api/user/friends/requests/fr3');
      await repo.removeFriend('clerk_c');
      expect(last, 'DELETE /api/user/friends/clerk_c');
    });
  });

  group('UserRepository', () {
    test('searchUsers parses friendRequestStatus', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/user/search');
        expect(request.url.queryParameters['q'], 'bob');
        return _json([
          {
            'clerkId': 'clerk_b',
            'name': 'Bob',
            'username': 'bob',
            'imageUrl': 'https://img/b.png',
            'friendRequestStatus': 'none',
            'friendRequestId': null,
          },
        ]);
      });

      final users = await UserRepository(_api(mock)).searchUsers('bob');
      expect(users.single.user.clerkId, 'clerk_b');
      expect(users.single.friendRequestStatus, 'none');
      expect(users.single.isFriend, isFalse);
    });

    test('updateProfile sends profileImageUrl and parses the user', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/api/user/profile');
        expect(jsonDecode(request.body), {
          'profileImageUrl': 'https://img.clerk.com/new.png',
        });
        return _json({
          'clerkId': 'clerk_a',
          'username': 'alice',
          'imageUrl': 'https://img.clerk.com/new.png',
        });
      });

      final user =
          await UserRepository(_api(mock)).updateProfile(profileImageUrl: 'https://img.clerk.com/new.png');
      expect(user.clerkId, 'clerk_a');
      expect(user.profileImageUrl, 'https://img.clerk.com/new.png');
    });

    test('updateProfile with empty profileImageUrl clears the avatar',
        () async {
      final mock = MockClient((request) async {
        expect(jsonDecode(request.body), {'profileImageUrl': ''});
        return _json({
          'clerkId': 'clerk_a',
          'username': 'alice',
          'imageUrl': null,
        });
      });

      final user =
          await UserRepository(_api(mock)).updateProfile(profileImageUrl: '');
      expect(user.profileImageUrl, isNull);
    });

    test('updateProfile omits null fields', () async {
      final mock = MockClient((request) async {
        expect(jsonDecode(request.body), {'username': 'alice2'});
        return _json({
          'clerkId': 'clerk_a',
          'username': 'alice2',
          'imageUrl': null,
        });
      });

      final user =
          await UserRepository(_api(mock)).updateProfile(username: 'alice2');
      expect(user.username, 'alice2');
    });
  });

  group('DictionaryRepository', () {
    test('saveDictionary surfaces 409 version conflicts as ApiException', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/chats/c1/dictionary');
        return http.Response(
          jsonEncode({'error': 'dictionary.version must be newer than the stored one'}),
          409,
          headers: _jsonHeaders,
        );
      });

      await expectLater(
        DictionaryRepository(_api(mock)).saveDictionary(
          chatId: 'c1',
          version: 1,
          ciphertext: 'ct',
          iv: 'iv',
          authTag: 'tag',
          wraps: const [],
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });
}
