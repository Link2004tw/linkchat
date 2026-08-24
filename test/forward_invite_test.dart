import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/dictionary.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/messages_repository.dart';
import 'package:chat_app/screens/forward_to_screen.dart';
import 'package:chat_app/screens/join_invite_screen.dart';
import 'package:chat_app/widgets/chat/message_bubble.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

ApiClient _api(MockClient mock) =>
    ApiClient(getToken: () async => 'jwt', httpClient: mock);

ChatMessage _text(String id, String content, {String? author}) => ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: author == null
          ? null
          : ChatUser(clerkId: 'clerk_$author', username: author),
    );

final _dictEntries = const [
  DictEntry(code: 'm', meaning: 'Mark'),
  DictEntry(code: 'h', meaning: 'home'),
];

void main() {
  group('ForwardedFrom', () {
    test('parses from WS and REST, round-trips through toJson', () {
      const json = {
        'chatId': 'source-chat',
        'messageId': 'orig-msg',
        'authorId': 'clerk_bob',
        'username': 'bob',
      };
      final fromJson = ForwardedFrom.fromJson(json);
      expect(fromJson.chatId, 'source-chat');
      expect(fromJson.messageId, 'orig-msg');
      expect(fromJson.authorId, 'clerk_bob');
      expect(fromJson.username, 'bob');

      final msg = ChatMessage.fromWs({
        'messageId': 'new-msg',
        'content': 'copied',
        'author': {'userId': 'clerk_alice', 'username': 'alice'},
        'contentType': 'text',
        'forwardedFrom': json,
      });
      expect(msg.forwardedFrom?.messageId, 'orig-msg');
      expect(msg.toJson()['forwardedFrom'], json);
    });

    test('null forwardedFrom stays null on both parsers', () {
      final msg = ChatMessage.fromRest({
        '_id': 'm',
        'content': 'plain',
        'contentType': 'text',
      });
      expect(msg.forwardedFrom, isNull);
      expect(msg.toJson().containsKey('forwardedFrom'), isTrue);
      expect(msg.toJson()['forwardedFrom'], isNull);
    });
  });

  group('messageCopyText', () {
    test('text without a dictionary copies the raw content', () {
      final msg = _text('m1', 'see you tomorrow');
      expect(messageCopyText(msg, const []), 'see you tomorrow');
    });

    test('text with a dictionary expands codes (copies what you see)', () {
      final msg = _text('m1', 'm is at h today');
      expect(messageCopyText(msg, _dictEntries), 'Mark is at home today');
    });

    test('media copies the caption when present', () {
      final msg = ChatMessage(
        id: 'm2',
        content: 'https://res.cloudinary.com/x/photo.jpg',
        contentType: 'image',
        caption: 'm home',
      );
      expect(messageCopyText(msg, _dictEntries), 'Mark home');
    });

    test('media with no caption copies the raw URL', () {
      final msg = ChatMessage(
        id: 'm3',
        content: 'https://res.cloudinary.com/x/photo.jpg',
        contentType: 'image',
      );
      expect(messageCopyText(msg, const []), msg.content);
    });
  });

  group('repositories', () {
    test('MessagesRepository.forward POSTs to the right path', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/source/messages/m1/forward');
        expect(jsonDecode(request.body), {'targetChatId': 'target'});
        return _json({
          '_id': 'new-msg',
          'content': 'copied',
          'contentType': 'text',
          'author': {'userId': 'clerk_alice', 'username': 'alice'},
          'forwardedFrom': {'messageId': 'm1', 'chatId': 'source'},
        });
      });
      final result = await MessagesRepository(_api(mock)).forward(
        sourceChatId: 'source',
        messageId: 'm1',
        targetChatId: 'target',
      );
      expect(result.id, 'new-msg');
      expect(result.forwardedFrom?.messageId, 'm1');
    });

    test('MessagesRepository.forward same-chat omits forwardedFrom when own message', () async {
      // When forwarding your own message to the same chat, the server
      // should return a message WITHOUT forwardedFrom.
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/chats/chat1/messages/m1/forward');
        expect(jsonDecode(request.body), {'targetChatId': 'chat1'});
        return _json({
          '_id': 'new-msg-same',
          'content': 'my own text',
          'contentType': 'text',
          'author': {'userId': 'clerk_alice', 'username': 'alice'},
          'forwardedFrom': null,
        });
      });
      final result = await MessagesRepository(_api(mock)).forward(
        sourceChatId: 'chat1',
        messageId: 'm1',
        targetChatId: 'chat1',
      );
      expect(result.id, 'new-msg-same');
      expect(result.forwardedFrom, isNull);
    });

    test('MessagesRepository.forward same-chat keeps forwardedFrom for others', () async {
      // Forwarding someone else's message to the same chat should retain
      // the forwardedFrom tag.
      final mock = MockClient((request) async {
        return _json({
          '_id': 'new-msg-other',
          'content': 'their text',
          'contentType': 'text',
          'author': {'userId': 'clerk_alice', 'username': 'alice'},
          'forwardedFrom': {
            'messageId': 'm2',
            'chatId': 'chat1',
            'authorId': 'clerk_bob',
            'username': 'bob',
          },
        });
      });
      final result = await MessagesRepository(_api(mock)).forward(
        sourceChatId: 'chat1',
        messageId: 'm2',
        targetChatId: 'chat1',
      );
      expect(result.id, 'new-msg-other');
      expect(result.forwardedFrom?.messageId, 'm2');
      expect(result.forwardedFrom?.authorId, 'clerk_bob');
    });

    test('invite-link endpoints hit the right routes', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/chats/c1/invite-link' &&
            request.method == 'POST') {
          return _json({
            'code': 'abc',
            'url': 'https://chat.example/join/abc',
            'chatId': 'c1',
            'inviteCode': 'abc',
          });
        }
        if (request.url.path == '/api/chats/invite/abc') {
          return _json({
            'chatId': 'c9',
            'name': 'Secret Room',
            'access': 'private',
            'participantCount': 3,
          });
        }
        if (request.url.path == '/api/chats/invite/abc/join') {
          return _json({'chatId': 'c9', 'alreadyMember': false});
        }
        return _json({'message': 'ok'});
      });
      final repo = ChatsRepository(_api(mock));

      final link = await repo.createInviteLink('c1');
      expect(link.code, 'abc');
      expect(link.url, 'https://chat.example/join/abc');

      await repo.revokeInviteLink('c1');
      expect(paths, contains('DELETE /api/chats/c1/invite-link'));

      final info = await repo.getInviteInfo('abc');
      expect(info.chatId, 'c9');
      expect(info.name, 'Secret Room');

      final joined = await repo.joinByCode('abc');
      expect(joined.chatId, 'c9');
      expect(joined.alreadyMember, isFalse);
      expect(paths, contains('GET /api/chats/invite/abc'));
      expect(paths, contains('POST /api/chats/invite/abc/join'));
    });
  });

  group('ForwardToScreen', () {
    testWidgets('lists other chats and pops with the chosen target',
        (tester) async {
      String? popped;
      final chats = [
        ChatSummary(id: 'c1', name: 'Backend Team', access: 'public'),
        ChatSummary(id: 'c2', name: 'Design Team', access: 'private'),
        ChatSummary(id: 'dm1', access: 'direct',
            otherUser: const ChatOtherUser(clerkId: 'clerk_bob', name: 'Bob')),
      ];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatListProvider.overrideWith(() => _StaticChatListController(chats)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = (await Navigator.of(context)
                            .push<ChatSummary>(MaterialPageRoute(
                          builder: (_) =>
                              ForwardToScreen(currentChatId: 'c1'),
                        )))
                        ?.id;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // All chats are shown, including the current one.
      expect(find.text('Backend Team'), findsOneWidget);
      expect(find.text('Design Team'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(popped, 'dm1');
    });
  });

  group('MessageBubble', () {
    testWidgets('long-press shows Copy + Forward; Forward reports the id',
        (tester) async {
      String? forwarded;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _text('m1', 'hi', author: 'alice'),
            isMine: false,
            onForward: (id) => forwarded = id,
          ),
        ),
      ));

      await tester.longPress(find.text('hi'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Forward'), findsOneWidget);

      await tester.tap(find.text('Forward'));
      await tester.pumpAndSettle();
      expect(forwarded, 'm1');
    });

    testWidgets('renders the "Forwarded from" tag', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        content: 'copied text',
        contentType: 'text',
        forwardedFrom: const ForwardedFrom(
          chatId: 'source',
          messageId: 'orig',
          authorId: 'clerk_bob',
          username: 'bob',
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg, isMine: false)),
      ));
      expect(find.text('Forwarded from bob'), findsOneWidget);
    });
  });

  group('JoinInviteScreen', () {
    testWidgets('previews the room then joins and opens it', (tester) async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/chats/invite/abc') {
          return _json({
            'chatId': 'c9',
            'name': 'Secret Room',
            'access': 'private',
            'participantCount': 3,
          });
        }
        if (request.url.path == '/api/chats/invite/abc/join') {
          expect(request.method, 'POST');
          return _json({'chatId': 'c9', 'alreadyMember': false});
        }
        return _json({'message': 'unexpected'}, 404);
      });
      final api = _api(mock);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatsRepositoryProvider.overrideWithValue(ChatsRepository(api)),
          // Keeps the post-join `invalidate(chatListProvider)` offline.
          chatListProvider.overrideWith(
            () => _StaticChatListController(const []),
          ),
          chatRoomProvider.overrideWith(
            () => _StaticRoomController(const ChatRoomState(
              isConnected: true,
              isLoading: false,
            )),
          ),
        ],
        child: const MaterialApp(home: JoinInviteScreen()),
      ));

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Preview room'));
      await tester.pumpAndSettle();

      expect(find.text('Secret Room'), findsOneWidget);
      expect(find.textContaining('3 members'), findsOneWidget);

      await tester.tap(find.text('Join room'));
      await tester.pumpAndSettle();

      expect(paths, contains('POST /api/chats/invite/abc/join'));
      expect(find.text('Secret Room'), findsWidgets); // opened the room
    });

    testWidgets('invalid code shows the error instead of the preview',
        (tester) async {
      final mock = MockClient((request) async {
        return _json({'message': 'Invite code not found'}, 404);
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatsRepositoryProvider.overrideWithValue(
            ChatsRepository(_api(mock)),
          ),
        ],
        child: const MaterialApp(home: JoinInviteScreen()),
      ));

      await tester.enterText(find.byType(TextField), 'nope');
      await tester.tap(find.text('Preview room'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not found'), findsOneWidget);
      expect(find.text('Join room'), findsNothing);
    });
  });
}

class _StaticRoomController extends ChatRoomController {
  _StaticRoomController(this._state);
  final ChatRoomState _state;
  @override
  ChatRoomState build(String chatId) => _state;
}

class _StaticChatListController extends ChatListController {
  _StaticChatListController(this._chats);
  final List<ChatSummary> _chats;
  @override
  AsyncValue<List<ChatSummary>> build() => AsyncData(_chats);
}