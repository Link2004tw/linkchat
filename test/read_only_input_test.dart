import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/friend.dart';
import 'package:chat_app/models/friend_request.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/providers/friends_providers.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/chats_repository.dart';
import 'package:chat_app/repositories/friends_repository.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

/// Mutable friends-list source the overridden [friendsProvider] reads, so a
/// test can simulate the DM partner becoming a friend mid-session.
final friendsSourceProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => const []);

/// A controller that returns a fixed room state instead of connecting to
/// the chat socket.
class _FakeRoomController extends ChatRoomController {
  _FakeRoomController(this._state);

  final ChatRoomState _state;

  @override
  ChatRoomState build(String chatId) => _state;
}

const _lockedHint = 'Only admins can send in this room';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

/// `GET /chats/:id/info` payload for the given role + policy.
Map<String, dynamic> _infoJson(String myRelation, String canSendMessages) => {
      '_id': 'c1',
      'name': 'Room',
      'access': 'public',
      'canSendMessages': canSendMessages,
      'createdBy': 'clerk_alice',
      'myRelation': myRelation,
      'participants': [
        {
          'user': {'userId': 'clerk_alice', 'username': 'alice'},
          'role': 'owner',
        },
      ],
    };

ChatRoomState _emptyRoom() => ChatRoomState(
      messages: const [],
      isLoading: false,
      isConnected: true,
      hasMoreHistory: false,
    );

/// Room screen with an optional info endpoint + signed-in user.
Widget _roomScreen(
  ChatRoomState state, {
  http.Client? infoClient,
  http.Client? friendsClient,
  String? otherUserId,
  ChatUser? me,
  Stream<ChatListEvent>? events,
  bool isDm = false,
}) {
  final overrides = <Override>[
    chatRoomProvider.overrideWith(() => _FakeRoomController(state)),
    if (infoClient != null)
      chatsRepositoryProvider
          .overrideWithValue(ChatsRepository(
            ApiClient(getToken: () async => 'jwt', httpClient: infoClient),
          )),
    if (friendsClient != null)
      friendsRepositoryProvider.overrideWithValue(FriendsRepository(
        ApiClient(getToken: () async => 'jwt', httpClient: friendsClient),
      )),
    if (me != null) currentUserProvider.overrideWithValue(me),
    if (events != null) chatListEventsProvider.overrideWith((ref) => events),
  ];
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      home: ChatRoomScreen(
        chat: ChatSummary(
          id: 'c1',
          name: isDm ? 'alice' : 'Room',
          access: isDm ? 'direct' : 'public',
          otherUser: otherUserId == null
              ? null
              : ChatOtherUser(clerkId: otherUserId, name: 'bob'),
        ),
      ),
    ),
  );
}

void main() {
  group('ChatInputBar canSend', () {
    testWidgets('locked state shows the hint and hides the input row',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
        canSend: false,
      )));
      expect(find.text(_lockedHint), findsOneWidget);
      expect(find.text('Message'), findsNothing);
      expect(find.byIcon(Icons.send), findsNothing);
    });

    testWidgets('default (canSend true) shows the normal input row',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
      )));
      expect(find.text(_lockedHint), findsNothing);
      expect(find.text('Message'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });
  });

  group('ChatRoomScreen read-only input', () {
    testWidgets('locks input when a room-update event sets admins-only',
        (tester) async {
      final controller = StreamController<ChatListEvent>();
      addTearDown(controller.close);

      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        events: controller.stream,
      ));
      await tester.pump();
      expect(find.text(_lockedHint), findsNothing);

      controller.add(const ChatListRoomUpdateEvent(
        chatId: 'c1',
        updates: {'canSendMessages': 'admins'},
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text(_lockedHint), findsOneWidget);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('keeps input enabled for an admin of an admins-only room',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson('owner', 'admins'));
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        infoClient: mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text(_lockedHint), findsNothing);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('locks input for a plain member of an admins-only room',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson('member', 'admins'));
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        infoClient: mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text(_lockedHint), findsOneWidget);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('locks a DM disabled by a friend removal with its own hint',
        (tester) async {
      const dmHint = "The user is no longer your friend you can't text them anymore";
      final mock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson('member', 'admins'));
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        infoClient: mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        isDm: true,
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text(dmHint), findsOneWidget);
      expect(find.text(_lockedHint), findsNothing);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('keeps an open DM input editable (policy everyone)',
        (tester) async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson('member', 'everyone'));
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        infoClient: mock,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        isDm: true,
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text(_lockedHint), findsNothing);
      expect(find.text('Message'), findsOneWidget);
    });
  });

  group('ChatRoomScreen locked-DM friend CTA', () {
    const dmHint =
        "The user is no longer your friend you can't text them anymore";

    MockClient friendsMock({
      required List<Map<String, dynamic>> friends,
      List<Map<String, dynamic>> outgoing = const [],
      void Function(String method, String path)? onCall,
    }) {
      return MockClient((request) async {
        onCall?.call(request.method, request.url.path);
        if (request.url.path == '/api/user/friends' &&
            request.method == 'GET') {
          return _json(friends);
        }
        if (request.url.path == '/api/user/friends/requests') {
          return _json({
            'ingoingRequests': <Object>[],
            'outgoingRequests': outgoing,
          });
        }
        if (request.url.path == '/api/user/friends' &&
            request.method == 'POST') {
          return _json({'success': true, 'requestId': 'fr1'});
        }
        return _json({'success': true});
      });
    }

    Future<void> pumpLockedDm(WidgetTester tester, http.Client friendsClient,
        {List<Map<String, dynamic>> outgoing = const []}) async {
      final infoMock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          return _json(_infoJson('member', 'admins'));
        }
        return _json({'success': true});
      });
      await tester.pumpWidget(_roomScreen(
        _emptyRoom(),
        infoClient: infoMock,
        friendsClient: friendsClient,
        me: const ChatUser(clerkId: 'clerk_alice', username: 'alice'),
        otherUserId: 'clerk_bob',
        isDm: true,
      ));
      await tester.pump();
      await tester.pump();
      await tester
          .pump(); // friends + pending-requests futures resolve
    }

    testWidgets('renders a disabled input with hint + Add-as-friend CTA',
        (tester) async {
      await pumpLockedDm(tester, friendsMock(friends: const []));

      // Input row stays visible but disabled.
      expect(find.text('Message'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isFalse,
      );
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(
        tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send),
        ).onPressed,
        isNull,
      );
      expect(find.text(dmHint), findsOneWidget);
      expect(find.text('Add as friend'), findsOneWidget);
    });

    testWidgets('CTA sends a friend request and shows a confirmation',
        (tester) async {
      final calls = <String>[];
      await pumpLockedDm(tester, friendsMock(
        friends: const [],
        onCall: (method, path) => calls.add('$method $path'),
      ));

      await tester.tap(find.text('Add as friend'));
      await tester.pump();
      await tester.pump();

      expect(calls, contains('POST /api/user/friends'));
      expect(find.text('Friend request sent'), findsOneWidget);

      // Let the snackbar's auto-hide timer elapse so no timers are pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('CTA disables itself until the request completes',
        (tester) async {
      final postGate = Completer<void>();
      final friendsMock = MockClient((request) async {
        if (request.url.path == '/api/user/friends' &&
            request.method == 'POST') {
          await postGate.future;
          return _json({'success': true, 'requestId': 'fr1'});
        }
        if (request.url.path == '/api/user/friends' &&
            request.method == 'GET') {
          return _json([]);
        }
        if (request.url.path == '/api/user/friends/requests') {
          return _json({
            'ingoingRequests': <Object>[],
            'outgoingRequests': <Object>[],
          });
        }
        return _json({'success': true});
      });
      await pumpLockedDm(tester, friendsMock);

      // Tap → in-flight: spinner shows and the button is disabled.
      await tester.tap(find.text('Add as friend'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      // Complete the request → the button re-enables.
      postGate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('no CTA when the partner is already a friend',
        (tester) async {
      await pumpLockedDm(tester, friendsMock(friends: [
        {'_id': 'u2', 'userId': 'clerk_bob', 'username': 'bob'},
      ]));

      expect(find.text(dmHint), findsOneWidget);
      expect(find.text('Add as friend'), findsNothing);
    });

    testWidgets('no CTA when a request is already pending',
        (tester) async {
      await pumpLockedDm(tester, friendsMock(
        friends: const [],
        outgoing: [
          {
            '_id': 'fr9',
            'to': {'userId': 'clerk_bob', 'username': 'bob'},
            'status': 'pending',
          },
        ],
      ));

      expect(find.text(dmHint), findsOneWidget);
      expect(find.text('Add as friend'), findsNothing);
    });
  });

  group('ChatRoomScreen stale-lock self-heal', () {
    const dmHint =
        "The user is no longer your friend you can't text them anymore";

    testWidgets(
        'locked DM unlocks when the partner becomes a friend again '
        '(missed room-update)', (tester) async {
      // First info read = locked; the heal refetch happens after the accept
      // has reset the policy server-side → everyone.
      var infoCalls = 0;
      final infoMock = MockClient((request) async {
        if (request.url.path == '/api/chats/c1/info') {
          infoCalls++;
          return _json(_infoJson('member', infoCalls <= 1 ? 'admins' : 'everyone'));
        }
        return _json({'success': true});
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatRoomProvider.overrideWith(() => _FakeRoomController(_emptyRoom())),
          chatsRepositoryProvider.overrideWithValue(ChatsRepository(
            ApiClient(getToken: () async => 'jwt', httpClient: infoMock),
          )),
          currentUserProvider
              .overrideWithValue(const ChatUser(clerkId: 'clerk_alice', username: 'alice')),
          chatListEventsProvider.overrideWith((ref) => const Stream.empty()),
          friendRequestsProvider.overrideWith((ref) async => const FriendRequests()),
          friendsProvider.overrideWith((ref) async => ref
              .watch(friendsSourceProvider)
              .map(Friend.fromJson)
              .toList()),
        ],
        child: MaterialApp(
          home: ChatRoomScreen(
            chat: ChatSummary(
              id: 'c1',
              name: 'alice',
              access: 'direct',
              otherUser: const ChatOtherUser(clerkId: 'clerk_bob', name: 'bob'),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Locked non-friend DM: disabled input + CTA.
      expect(find.text(dmHint), findsOneWidget);
      expect(find.text('Add as friend'), findsOneWidget);

      // The request gets accepted elsewhere → friends list refreshes to
      // include the partner. No room-update event is simulated — only the
      // friends provider changes.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatRoomScreen)),
      );
      container.read(friendsSourceProvider.notifier).state = [
        {'_id': 'u2', 'userId': 'clerk_bob', 'username': 'bob'},
      ];
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The stale lock healed: input enabled, hint + CTA gone. The heal
      // refetched the room info, which now reports `everyone`.
      expect(infoCalls, greaterThanOrEqualTo(2));
      expect(find.text(dmHint), findsNothing);
      expect(find.text('Add as friend'), findsNothing);
      expect(find.text('Message'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isTrue,
      );
    });
  });
}