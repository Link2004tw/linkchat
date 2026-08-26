import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/friend.dart';
import 'package:chat_app/models/friend_request.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';

void main() {
  group('ChatMessage.fromWs', () {
    test(
      'parses a text message with epoch-ms timestamp and string replyTo',
      () {
        final json = {
          'type': 'message',
          'messageId': 'msg123',
          'content': 'hello',
          'contentType': 'text',
          'author': {
            '_id': 'u1',
            'username': 'alice',
            'profileImageUrl': 'https://img/a.png',
            'userId': 'clerk_alice',
          },
          'createdAt': 1700000000123,
          'replyTo': 'msgPrev',
          'isEdited': false,
        };

        final msg = ChatMessage.fromWs(json);

        expect(msg.id, 'msg123');
        expect(msg.content, 'hello');
        expect(msg.author?.clerkId, 'clerk_alice');
        expect(msg.author?.profileImageUrl, 'https://img/a.png');
        expect(
          msg.createdAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000123),
        );
        expect(msg.replyToId, 'msgPrev');
        expect(msg.isSystem, isFalse);
      },
    );

    test('accepts a populated replyTo object', () {
      final json = {
        'type': 'message',
        'messageId': 'm2',
        'content': 'reply to you',
        'author': {'_id': 'u2', 'username': 'bob', 'userId': 'clerk_bob'},
        'createdAt': 1700000000123,
        'replyTo': {'_id': 'msgPrev', 'content': 'original'},
      };

      expect(ChatMessage.fromWs(json).replyToId, 'msgPrev');
    });

    test('parses a file message with nullable fields', () {
      final json = {
        'type': 'message',
        'messageId': 'm3',
        'content': 'https://res.cloudinary.com/x/image.jpg',
        'contentType': 'image',
        'fileName': 'photo.jpg',
        'mimeType': 'image/jpeg',
        'fileSize': 2048,
        'author': {'_id': 'u1', 'username': 'alice'},
        'createdAt': 1700000000123,
      };

      final msg = ChatMessage.fromWs(json);
      expect(msg.contentType, 'image');
      expect(msg.fileName, 'photo.jpg');
      expect(msg.mimeType, 'image/jpeg');
      expect(msg.fileSize, 2048);
      expect(msg.caption, isNull);
    });
  });

  group('ChatMessage.fromRest', () {
    test('parses ISO timestamp and populated replyTo', () {
      final json = {
        '_id': 'm4',
        'content': 'decrypted text',
        'contentType': 'text',
        'author': {'_id': 'u1', 'username': 'alice', 'userId': 'clerk_alice'},
        'createdAt': '2025-01-01T10:00:00.000Z',
        'isEdited': true,
        'event': null,
        'replyTo': {'_id': 'm0', 'content': 'original'},
      };

      final msg = ChatMessage.fromRest(json);
      expect(msg.id, 'm4');
      expect(msg.isEdited, isTrue);
      // Models normalize to local time.
      expect(
        msg.createdAt,
        DateTime.parse('2025-01-01T10:00:00.000Z').toLocal(),
      );
      expect(msg.replyToId, 'm0');
    });
  });

  group('MessagePage', () {
    test('parses pagination metadata', () {
      final json = {
        'messages': [
          {
            '_id': 'm1',
            'content': 'a',
            'author': {'username': 'alice'},
          },
          {
            '_id': 'm2',
            'content': 'b',
            'author': {'username': 'bob'},
          },
        ],
        'name': 'General',
        'more': true,
        'nextCursor': 'm1',
        'canSendMessages': 'admins',
        'isDm': false,
      };

      final page = MessagePage.fromJson(json);
      expect(page.messages, hasLength(2));
      expect(page.messages.first.content, 'a');
      expect(page.more, isTrue);
      expect(page.nextCursor, 'm1');
      expect(page.canSendMessages, 'admins');
      expect(page.isDm, isFalse);
    });
  });

  group('ChatLastMessage', () {
    test('parses contentType and mediaUrl from the REST payload', () {
      final json = {
        'content': '📷 Photo',
        'contentType': 'image',
        'mediaUrl': 'https://res.cloudinary.com/x/image.jpg',
        'sentAt': '2025-01-01T09:59:00.000Z',
        'senderId': 'alice',
      };

      final last = ChatLastMessage.fromJson(json);
      expect(last.content, '📷 Photo');
      expect(last.contentType, 'image');
      expect(last.mediaUrl, 'https://res.cloudinary.com/x/image.jpg');
      expect(last.senderName, 'alice');
    });

    test('mediaUrl round-trips through toJson', () {
      final last = ChatLastMessage(
        content: 'caption',
        contentType: 'image',
        mediaUrl: 'https://img/x.png',
      );
      expect(
        ChatLastMessage.fromJson(last.toJson()).mediaUrl,
        'https://img/x.png',
      );
    });

    test('text messages have no mediaUrl', () {
      final last = ChatLastMessage.fromJson({
        'content': 'hi',
        'contentType': 'text',
      });
      expect(last.mediaUrl, isNull);
    });

    test('previewText keeps text verbatim', () {
      final last = ChatLastMessage(content: 'ship it', contentType: 'text');
      expect(last.previewText, 'ship it');
    });

    test('previewText shows a label for caption-less media', () {
      final image = ChatLastMessage(content: '', contentType: 'image');
      expect(image.previewText, '📷 Photo');

      final video = ChatLastMessage(content: '', contentType: 'video');
      expect(video.previewText, '🎬 Video');

      final file = ChatLastMessage(content: '', contentType: 'file');
      expect(file.previewText, '📎 File');
    });

    test('previewText prefers the caption over the label', () {
      final last = ChatLastMessage(content: 'my caption', contentType: 'image');
      expect(last.previewText, 'my caption');
    });

    test('previewText never shows a raw media URL', () {
      final last = ChatLastMessage(
        content: 'https://res.cloudinary.com/x/image.jpg',
        contentType: 'image',
      );
      expect(last.previewText, '📷 Photo');
    });

    test('previewText falls back for unknown content', () {
      expect(
        ChatLastMessage(content: '', contentType: null).previewText,
        'New message',
      );
      expect(
        ChatLastMessage(content: 'hi', contentType: null).previewText,
        'hi',
      );
    });
  });

  group('RoomInfo', () {
    test('parses participants, roles and myRelation', () {
      final json = {
        '_id': 'chat1',
        'name': 'Backend Team',
        'description': 'A room for the backend team',
        'access': 'public',
        'canSendMessages': 'admins',
        'createdBy': 'clerk_alice',
        'inviteCode': 'ABC123',
        'pictureUrl': 'https://img/room.png',
        'myRelation': 'member',
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
            'user': {'userId': 'clerk_bob', 'username': 'bob'},
            'role': 'guest',
          },
        ],
      };

      final info = RoomInfo.fromJson(json);
      expect(info.id, 'chat1');
      expect(info.name, 'Backend Team');
      expect(info.description, 'A room for the backend team');
      expect(info.access, 'public');
      expect(info.canSendMessages, 'admins');
      expect(info.createdBy, 'clerk_alice');
      expect(info.inviteCode, 'ABC123');
      expect(info.pictureUrl, 'https://img/room.png');
      expect(info.myRelation, 'member');
      expect(info.isAdmin, isFalse);
      expect(info.isDm, isFalse);
      expect(info.participants, hasLength(2));
      expect(info.participants.first.clerkId, 'clerk_alice');
      expect(info.participants.first.username, 'alice');
      expect(info.participants.first.profileImageUrl, 'https://img/a.png');
      expect(info.participants.first.role, 'owner');
      expect(info.participants.first.isAdmin, isTrue);
      expect(info.participants[1].clerkId, 'clerk_bob');
      expect(info.participants[1].role, 'guest');
      expect(info.participants[1].isAdmin, isFalse);
    });

    test('owner and admin relations are admin', () {
      expect(
        RoomInfo.fromJson({
          '_id': 'c1',
          'access': 'public',
          'myRelation': 'owner',
        }).isAdmin,
        isTrue,
      );
      expect(
        RoomInfo.fromJson({
          '_id': 'c2',
          'access': 'public',
          'myRelation': 'admin',
        }).isAdmin,
        isTrue,
      );
      expect(
        RoomInfo.fromJson({
          '_id': 'c3',
          'access': 'public',
          'myRelation': 'guest',
        }).isAdmin,
        isFalse,
      );
    });

    test('missing participants and myRelation stay safe', () {
      final info = RoomInfo.fromJson(const {'_id': 'c1', 'access': 'direct'});
      expect(info.participants, isEmpty);
      expect(info.myRelation, isNull);
      expect(info.isAdmin, isFalse);
      expect(info.isDm, isTrue);
      expect(info.description, isEmpty);
    });
  });

  group('ChatSummary', () {
    test('parses a group chat', () {
      final json = {
        '_id': 'chat1',
        'name': 'Backend Team',
        'access': 'public',
        'unreadCount': 3,
        'updatedAt': '2025-01-01T10:00:00.000Z',
        'lastMessage': {
          'content': 'ship it',
          'sentAt': '2025-01-01T09:59:00.000Z',
          'senderId': 'alice', // backend sends the username here
        },
        'participantCount': 5,
        'previewMembers': ['alice', 'bob'],
        'pictureUrl': 'https://img/room.png',
      };

      final chat = ChatSummary.fromJson(json);
      expect(chat.id, 'chat1');
      expect(chat.displayName, 'Backend Team');
      expect(chat.unreadCount, 3);
      expect(chat.lastMessage?.content, 'ship it');
      expect(chat.lastMessage?.senderName, 'alice');
      expect(chat.participantCount, 5);
      expect(chat.pictureUrl, 'https://img/room.png');
      expect(chat.isDm, isFalse);
    });

    test('copyWith updates pictureUrl and keeps the rest', () {
      final chat = ChatSummary.fromJson({
        '_id': 'chat1',
        'name': 'Backend Team',
        'access': 'public',
        'pictureUrl': 'https://img/old.png',
      });
      final updated = chat.copyWith(pictureUrl: 'https://img/new.png');
      expect(updated.pictureUrl, 'https://img/new.png');
      expect(updated.name, 'Backend Team');
      final cleared = updated.copyWith(pictureUrl: '');
      expect(cleared.pictureUrl, '');
      expect(cleared.id, 'chat1');
    });

    test('parses a DM with otherUser and no name', () {
      final json = {
        '_id': 'chat2',
        'access': 'direct',
        'unreadCount': 0,
        'updatedAt': '2025-01-01T10:00:00.000Z',
        'otherUser': {
          'clerkId': 'clerk_bob',
          'name': 'Bob',
          'imageUrl': 'https://img/b.png',
        },
      };

      final chat = ChatSummary.fromJson(json);
      expect(chat.isDm, isTrue);
      expect(chat.displayName, 'Bob');
      expect(chat.otherUser?.clerkId, 'clerk_bob');
    });

    test('mutedByUser defaults to false and parses from JSON', () {
      final plain = ChatSummary.fromJson({
        '_id': 'chat1',
        'access': 'public',
      });
      expect(plain.mutedByUser, isFalse);

      final muted = ChatSummary.fromJson({
        '_id': 'chat1',
        'access': 'public',
        'mutedByUser': true,
      });
      expect(muted.mutedByUser, isTrue);
    });

    test('mutedByUser survives a JSON round-trip (offline cache)', () {
      final muted = ChatSummary.fromJson({
        '_id': 'chat1',
        'access': 'public',
        'mutedByUser': true,
      });
      final restored = ChatSummary.fromJson(muted.toJson());
      expect(restored.mutedByUser, isTrue);

      final unmuted = ChatSummary.fromJson({
        '_id': 'chat1',
        'access': 'public',
      });
      final restoredUnmuted = ChatSummary.fromJson(unmuted.toJson());
      expect(restoredUnmuted.mutedByUser, isFalse);
    });

    test('copyWith(mutedByUser: false) un-mutes; omitted keeps the value', () {
      final chat = ChatSummary(
        id: 'chat1',
        access: 'public',
        mutedByUser: true,
      );
      // Explicit false must reset the flag (false is not null).
      expect(chat.copyWith(mutedByUser: false).mutedByUser, isFalse);
      expect(chat.copyWith(mutedByUser: true).mutedByUser, isTrue);
      expect(chat.copyWith().mutedByUser, isTrue);
    });

    test('RoomParticipant parses selfMutedUntil and computes isSelfMutedNow',
        () {
      final json = {
        'user': {'userId': 'u1', 'username': 'bob'},
        'role': 'member',
        'selfMutedUntil':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      };
      final active = RoomParticipant.fromJson(json);
      expect(active.isSelfMutedNow, isTrue);

      final expired = RoomParticipant.fromJson({
        ...json,
        'selfMutedUntil': '2020-01-01T00:00:00.000Z',
      });
      expect(expired.isSelfMutedNow, isFalse);

      final never = RoomParticipant.fromJson({
        ...json,
        'selfMutedUntil': null,
      });
      expect(never.isSelfMutedNow, isFalse);
      expect(never.selfMutedUntil, isNull);
    });
  });

  group('UserSearchResult', () {
    test('parses search result with friendRequestStatus', () {
      final json = {
        'clerkId': 'clerk_bob',
        'name': 'Bob',
        'username': 'bob',
        'imageUrl': 'https://img/b.png',
        'friendRequestStatus': 'pending',
        'friendRequestId': 'fr1',
      };

      final result = UserSearchResult.fromJson(json);
      expect(result.user.clerkId, 'clerk_bob');
      expect(result.user.profileImageUrl, 'https://img/b.png');
      expect(result.friendRequestStatus, 'pending');
      expect(result.friendRequestId, 'fr1');
    });
  });

  group('Friend', () {
    test('parses friend with dmChatId', () {
      final json = {
        '_id': 'u9',
        'userId': 'clerk_carol',
        'username': 'carol',
        'firstName': 'Carol',
        'profileImageUrl': 'https://img/c.png',
        'dmChatId': 'dm99',
      };

      final friend = Friend.fromJson(json);
      expect(friend.dmChatId, 'dm99');
      expect(friend.displayName, 'Carol');
      expect(friend.clerkId, 'clerk_carol');
    });
  });

  group('FriendRequests', () {
    test('parses ingoing and outgoing lists', () {
      final json = {
        'ingoingRequests': [
          {
            '_id': 'fr1',
            'from': {'userId': 'clerk_dave', 'username': 'dave'},
            'status': 'pending',
            'message': 'hi',
            'createdAt': '2025-01-01T10:00:00.000Z',
          },
        ],
        'outgoingRequests': [
          {
            '_id': 'fr2',
            'to': {'userId': 'clerk_erin', 'username': 'erin'},
            'status': 'pending',
          },
        ],
      };

      final requests = FriendRequests.fromJson(json);
      expect(requests.ingoing, hasLength(1));
      expect(requests.ingoing.first.from.username, 'dave');
      expect(requests.outgoing, hasLength(1));
      expect(requests.outgoing.first.to.username, 'erin');
    });
  });

  group('WsEvent.fromJson', () {
    test('parses all chat event types', () {
      WsEvent parse(Map<String, dynamic> json) => WsEvent.fromJson(json);

      expect(
        parse({
          'type': 'message',
          'messageId': 'm1',
          'content': 'hi',
          'author': {'username': 'alice'},
          'createdAt': 1700000000123,
        }),
        isA<WsMessageEvent>(),
      );
      expect(
        parse({'type': 'edit', 'messageId': 'm1', 'content': 'edited'}),
        isA<WsEditEvent>(),
      );
      expect(
        parse({'type': 'delete', 'messageId': 'm1'}),
        isA<WsDeleteEvent>(),
      );
      expect(
        parse({'type': 'typing', 'userId': 'u1', 'username': 'alice'}),
        isA<WsTypingEvent>(),
      );
      expect(
        parse({
          'type': 'presence',
          'userId': 'u1',
          'username': 'alice',
          'status': 'online',
        }),
        isA<WsPresenceEvent>(),
      );
      expect(
        parse({'type': 'join', 'text': 'alice joined the chat'}),
        isA<WsSystemEvent>(),
      );
      expect(
        parse({'type': 'file-progress', 'progress': 42}),
        isA<WsFileProgressEvent>(),
      );
      expect(
        parse({
          'type': 'file-complete',
          'messageId': 'm9',
          'url': 'https://img/x.png',
        }),
        isA<WsFileCompleteEvent>(),
      );
      expect(parse({'type': 'error', 'text': 'boom'}), isA<WsErrorEvent>());
    });

    test('room-update system message frame parses as a message event', () {
      // The backend now broadcasts a persisted admin notice as a regular
      // `type: "message"` frame (real id) so the live row and its history
      // replay share an identity and dedupe.
      final event =
          WsEvent.fromJson({
                'type': 'message',
                'messageId': 'sys-1',
                'content': 'alice updated the room',
                'contentType': 'system',
                'event': 'room-update',
                'author': {'userId': 'clerk_alice', 'username': 'alice'},
                'createdAt': 1700000000123,
              })
              as WsMessageEvent;
      expect(event.message.id, 'sys-1');
      expect(event.message.isSystem, isTrue);
      expect(event.message.event, 'room-update');
      expect(event.message.content, 'alice updated the room');
    });

    test('presence status maps to isOnline', () {
      final online =
          WsEvent.fromJson({
                'type': 'presence',
                'userId': 'u1',
                'username': 'a',
                'status': 'online',
              })
              as WsPresenceEvent;
      final offline =
          WsEvent.fromJson({
                'type': 'presence',
                'userId': 'u1',
                'username': 'a',
                'status': 'offline',
              })
              as WsPresenceEvent;

      expect(online.isOnline, isTrue);
      expect(offline.isOnline, isFalse);
    });
  });

  group('ChatListEvent.fromJson', () {
    test('parses new-message and unread-update', () {
      final newMsg =
          ChatListEvent.fromJson({
                'type': 'new-message',
                'chatId': 'chat1',
                'lastMessage': {
                  'content': 'yo',
                  'contentType': 'text',
                  'author': {'_id': 'u1', 'username': 'alice'},
                  'createdAt': 1700000000123,
                },
                'unreadCount': 2,
              })
              as ChatListNewMessageEvent;

      expect(newMsg.chatId, 'chat1');
      expect(newMsg.lastMessage?.content, 'yo');
      expect(newMsg.unreadCount, 2);

      final unread =
          ChatListEvent.fromJson({
                'type': 'unread-update',
                'chatId': 'chat1',
                'unreadCount': 0,
              })
              as ChatListUnreadUpdateEvent;

      expect(unread.unreadCount, 0);
    });

    test('parses friend-request with sender details', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-request',
                'requestId': 'req1',
                'from': {
                  'clerkId': 'clerk_sender',
                  'username': 'alice',
                  'profileImageUrl': 'https://img/a.png',
                },
              })
              as ChatListFriendRequestEvent;

      expect(event.requestId, 'req1');
      expect(event.from.clerkId, 'clerk_sender');
      expect(event.from.username, 'alice');
      expect(event.from.profileImageUrl, 'https://img/a.png');
    });

    test('parses friend-request without profileImageUrl', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-request',
                'requestId': 'req2',
                'from': {'clerkId': 'clerk_sender', 'username': 'bob'},
              })
              as ChatListFriendRequestEvent;

      expect(event.from.clerkId, 'clerk_sender');
      expect(event.from.username, 'bob');
      expect(event.from.profileImageUrl, isNull);
    });

    test('parses friend-request-accepted with the acceptor', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-request-accepted',
                'requestId': 'req3',
                'from': {'clerkId': 'clerk_acceptor', 'username': 'carol'},
              })
              as ChatListFriendRequestAcceptedEvent;

      expect(event.requestId, 'req3');
      expect(event.from.clerkId, 'clerk_acceptor');
      expect(event.from.username, 'carol');
    });

    test('parses friend-request-cancelled with the sender', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-request-cancelled',
                'requestId': 'req4',
                'from': {'clerkId': 'clerk_sender', 'username': 'alice'},
              })
              as ChatListFriendRequestCancelledEvent;

      expect(event.requestId, 'req4');
      expect(event.from.clerkId, 'clerk_sender');
      expect(event.from.username, 'alice');
    });

    test('parses friend-request-declined with the decliner', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-request-declined',
                'requestId': 'req5',
                'from': {'clerkId': 'clerk_decliner', 'username': 'bob'},
              })
              as ChatListFriendRequestDeclinedEvent;

      expect(event.requestId, 'req5');
      expect(event.from.clerkId, 'clerk_decliner');
      expect(event.from.username, 'bob');
    });

    test('parses friend-removed with the remover', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-removed',
                'clerkId': 'clerk_remover',
                'username': 'dan',
              })
              as ChatListFriendRemovedEvent;

      expect(event.clerkId, 'clerk_remover');
      expect(event.username, 'dan');
    });

    test('parses friend-removed without a username', () {
      final event =
          ChatListEvent.fromJson({
                'type': 'friend-removed',
                'clerkId': 'clerk_remover',
              })
              as ChatListFriendRemovedEvent;

      expect(event.clerkId, 'clerk_remover');
      expect(event.username, isNull);
    });
  });
}
