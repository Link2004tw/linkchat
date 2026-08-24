import 'json_utils.dart';
import 'message.dart';
import 'user.dart';

/// Incoming events from `/ws/chat`. Parsed by `WsEvent.fromJson` from the
/// backend's `BroadcastMessage` union (see `backend/plugins/websocket.ts`).
sealed class WsEvent {
  const WsEvent();

  factory WsEvent.fromJson(Map<String, dynamic> json) {
    final type = asString(json['type']) ?? '';
    return switch (type) {
      'message' => WsMessageEvent(
          message: ChatMessage.fromWs(json),
        ),
      'edit' => WsEditEvent(
          messageId: asString(json['messageId']) ?? '',
          content: asString(json['content']) ?? '',
          mentions: json['mentions'] is List
              ? (json['mentions'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map(MentionUser.fromJson)
                  .toList()
              : const [],
          mentionAll: asBool(json['mentionAll']),
        ),
      'delete' => WsDeleteEvent(
          messageId: asString(json['messageId']) ?? '',
        ),
      'typing' => WsTypingEvent(
          userId: asString(json['userId']) ?? '',
          username: asString(json['username']) ?? '',
        ),
      'presence' => WsPresenceEvent(
          userId: asString(json['userId']) ?? '',
          username: asString(json['username']) ?? '',
          isOnline: asString(json['status']) == 'online',
        ),
      'join' || 'leave' || 'kick' || 'invite' || 'room-update' || 'system' =>
        WsSystemEvent(
          type: type,
          text: asString(json['text']) ?? '',
          createdAt: asDateTime(json['createdAt']),
        ),
      'file-ack' => WsFileAckEvent(
          status: asString(json['status']) ?? '',
        ),
      'file-progress' => WsFileProgressEvent(
          progress: asInt(json['progress']) ?? 0,
        ),
      'file-complete' => WsFileCompleteEvent(
          messageId: asString(json['messageId']) ?? '',
          url: asString(json['url']) ?? '',
        ),
      'dictionary-update' => WsDictionaryUpdateEvent(
          chatId: asString(json['chatId']) ?? '',
          version: asInt(json['version']) ?? 0,
        ),
      'read' => WsReadEvent(
          userId: asString(json['userId']) ?? '',
          username: asString(json['username']) ?? '',
          lastReadMessage: asString(json['lastReadMessage']),
          lastReadAt: asDateTime(json['lastReadAt']),
        ),
      'error' => WsErrorEvent(
          text: asString(json['text']) ?? 'Unknown error',
        ),
      _ => WsUnknownEvent(type: type, raw: json),
    };
  }
}

class WsMessageEvent extends WsEvent {
  const WsMessageEvent({required this.message});
  final ChatMessage message;
}

class WsEditEvent extends WsEvent {
  const WsEditEvent({
    required this.messageId,
    required this.content,
    this.mentions = const [],
    this.mentionAll = false,
  });
  final String messageId;
  final String content;
  final List<MentionUser> mentions;
  final bool mentionAll;
}

class WsDeleteEvent extends WsEvent {
  const WsDeleteEvent({required this.messageId});
  final String messageId;
}

class WsTypingEvent extends WsEvent {
  const WsTypingEvent({required this.userId, required this.username});
  final String userId;
  final String username;
}

class WsPresenceEvent extends WsEvent {
  const WsPresenceEvent({
    required this.userId,
    required this.username,
    required this.isOnline,
  });
  final String userId;
  final String username;
  final bool isOnline;
}

/// Read receipt: a member read up to [lastReadMessage] at [lastReadAt].
class WsReadEvent extends WsEvent {
  const WsReadEvent({
    required this.userId,
    required this.username,
    this.lastReadMessage,
    this.lastReadAt,
  });
  final String userId;
  final String username;
  final String? lastReadMessage;
  final DateTime? lastReadAt;
}

/// join | leave | kick | invite | room-update | system.
/// These carry `text`, not `content` — render as centered system rows.
class WsSystemEvent extends WsEvent {
  const WsSystemEvent({required this.type, required this.text, this.createdAt});
  final String type;
  final String text;
  final DateTime? createdAt;
}

class WsFileAckEvent extends WsEvent {
  const WsFileAckEvent({required this.status});
  final String status;
}

class WsFileProgressEvent extends WsEvent {
  const WsFileProgressEvent({required this.progress});
  final int progress;
}

class WsFileCompleteEvent extends WsEvent {
  const WsFileCompleteEvent({required this.messageId, required this.url});
  final String messageId;
  final String url;
}

/// Pushed after a member saves the chat dictionary, so open clients
/// re-fetch it (content-free ping; no secrets travel over WS).
class WsDictionaryUpdateEvent extends WsEvent {
  const WsDictionaryUpdateEvent({required this.chatId, required this.version});
  final String chatId;
  final int version;
}

class WsErrorEvent extends WsEvent {
  const WsErrorEvent({required this.text});
  final String text;
}

class WsUnknownEvent extends WsEvent {
  const WsUnknownEvent({required this.type, required this.raw});
  final String type;
  final Map<String, dynamic> raw;
}

/// Incoming events from `/ws/chat-list`.
sealed class ChatListEvent {
  const ChatListEvent();

  factory ChatListEvent.fromJson(Map<String, dynamic> json) {
    final type = asString(json['type']) ?? '';
    return switch (type) {
      'connected' => ChatListConnectedEvent(
          message: asString(json['message']) ?? '',
        ),
      'new-message' => ChatListNewMessageEvent(
          chatId: asString(json['chatId']) ?? '',
          lastMessage: json['lastMessage'] is Map<String, dynamic>
              ? ChatListLastMessage.fromJson(
                  json['lastMessage'] as Map<String, dynamic>)
              : null,
          unreadCount: asInt(json['unreadCount']) ?? 0,
          mentionedCount: asInt(json['mentionedCount']) ?? 0,
        ),
      'unread-update' => ChatListUnreadUpdateEvent(
          chatId: asString(json['chatId']) ?? '',
          unreadCount: asInt(json['unreadCount']) ?? 0,
          mentionedCount: asInt(json['mentionedCount']) ?? 0,
        ),
      'room-update' => ChatListRoomUpdateEvent(
          chatId: asString(json['chatId']) ?? '',
          updates: json['updates'] is Map<String, dynamic>
              ? (json['updates'] as Map<String, dynamic>)
              : const {},
        ),
      'invited' || 'kicked' || 'leave-chat' => ChatListMembershipEvent(
          type: type,
          chatId: asString(json['chatId']) ?? '',
          systemMessage: json['systemMessage'] is Map<String, dynamic>
              ? (json['systemMessage'] as Map<String, dynamic>)
              : null,
        ),
      'join-request' => ChatListJoinRequestEvent(
          chatId: asString(json['chatId']) ?? '',
          user: json['user'] is Map<String, dynamic>
              ? ChatUser.fromJson(json['user'] as Map<String, dynamic>)
              : null,
        ),
      'join-request-updated' => ChatListJoinRequestUpdatedEvent(
          chatId: asString(json['chatId']) ?? '',
          status: asString(json['status']) ?? '',
        ),
      'friend-request' => ChatListFriendRequestEvent(
          requestId: asString(json['requestId']) ?? '',
          from: json['from'] is Map<String, dynamic>
              ? ChatUser.fromJson(json['from'] as Map<String, dynamic>)
              : const ChatUser(username: 'Unknown'),
        ),
      'friend-request-accepted' => ChatListFriendRequestAcceptedEvent(
          requestId: asString(json['requestId']) ?? '',
          from: json['from'] is Map<String, dynamic>
              ? ChatUser.fromJson(json['from'] as Map<String, dynamic>)
              : const ChatUser(username: 'Unknown'),
        ),
      'friend-request-cancelled' => ChatListFriendRequestCancelledEvent(
          requestId: asString(json['requestId']) ?? '',
          from: json['from'] is Map<String, dynamic>
              ? ChatUser.fromJson(json['from'] as Map<String, dynamic>)
              : const ChatUser(username: 'Unknown'),
        ),
      'friend-request-declined' => ChatListFriendRequestDeclinedEvent(
          requestId: asString(json['requestId']) ?? '',
          from: json['from'] is Map<String, dynamic>
              ? ChatUser.fromJson(json['from'] as Map<String, dynamic>)
              : const ChatUser(username: 'Unknown'),
        ),
      'friend-removed' => ChatListFriendRemovedEvent(
          clerkId: asString(json['clerkId']) ?? '',
          username: asString(json['username']),
        ),
      'dictionary-update' => ChatListDictionaryUpdateEvent(
          chatId: asString(json['chatId']) ?? '',
          version: asInt(json['version']) ?? 0,
        ),
      _ => ChatListUnknownEvent(type: type, raw: json),
    };
  }
}

class ChatListConnectedEvent extends ChatListEvent {
  const ChatListConnectedEvent({required this.message});
  final String message;
}

/// Last-message preview pushed with `new-message` notifications.
class ChatListLastMessage {
  const ChatListLastMessage({
    required this.content,
    this.contentType,
    this.mediaUrl,
    this.author,
    this.createdAt,
  });

  final String content;
  final String? contentType;

  /// Raw media URL (image/video/file) for thumbnails; null for text.
  final String? mediaUrl;
  final ChatUser? author;
  final DateTime? createdAt;

  factory ChatListLastMessage.fromJson(Map<String, dynamic> json) =>
      ChatListLastMessage(
        content: asString(json['content']) ?? '',
        contentType: asString(json['contentType']),
        mediaUrl: asString(json['mediaUrl']),
        author: json['author'] is Map<String, dynamic>
            ? ChatUser.fromJson(json['author'] as Map<String, dynamic>)
            : null,
        createdAt: asDateTime(json['createdAt']),
      );
}

class ChatListNewMessageEvent extends ChatListEvent {
  const ChatListNewMessageEvent({
    required this.chatId,
    required this.lastMessage,
    required this.unreadCount,
    this.mentionedCount = 0,
  });
  final String chatId;
  final ChatListLastMessage? lastMessage;
  final int unreadCount;
  final int mentionedCount;
}

class ChatListUnreadUpdateEvent extends ChatListEvent {
  const ChatListUnreadUpdateEvent({
    required this.chatId,
    required this.unreadCount,
    this.mentionedCount = 0,
  });
  final String chatId;
  final int unreadCount;
  final int mentionedCount;
}

class ChatListRoomUpdateEvent extends ChatListEvent {
  const ChatListRoomUpdateEvent({
    required this.chatId,
    required this.updates,
  });
  final String chatId;
  final Map<String, dynamic> updates;
}

/// invited | kicked | leave-chat — membership changes pushed per user.
class ChatListMembershipEvent extends ChatListEvent {
  const ChatListMembershipEvent({
    required this.type,
    required this.chatId,
    this.systemMessage,
  });
  final String type;
  final String chatId;
  final Map<String, dynamic>? systemMessage;
}

class ChatListJoinRequestEvent extends ChatListEvent {
  const ChatListJoinRequestEvent({required this.chatId, this.user});
  final String chatId;
  final ChatUser? user;
}

class ChatListJoinRequestUpdatedEvent extends ChatListEvent {
  const ChatListJoinRequestUpdatedEvent({
    required this.chatId,
    required this.status,
  });
  final String chatId;
  final String status;
}

class ChatListUnknownEvent extends ChatListEvent {
  const ChatListUnknownEvent({required this.type, required this.raw});
  final String type;
  final Map<String, dynamic> raw;
}

/// `friend-request` — pushed to the **recipient** when a friend request is
/// sent. `from` is the sender.
class ChatListFriendRequestEvent extends ChatListEvent {
  const ChatListFriendRequestEvent({required this.requestId, required this.from});
  final String requestId;
  final ChatUser from;
}

/// `friend-request-accepted` — pushed to the **original sender** when a
/// request they sent is accepted. `from` is the acceptor (the user who
/// accepted), so the snackbar reads "X accepted your friend request".
class ChatListFriendRequestAcceptedEvent extends ChatListEvent {
  const ChatListFriendRequestAcceptedEvent({
    required this.requestId,
    required this.from,
  });
  final String requestId;
  final ChatUser from;
}

/// `friend-request-cancelled` — pushed to the **recipient** when the sender
/// cancels their pending request, so the incoming tile disappears live
/// (silent — no notification).
class ChatListFriendRequestCancelledEvent extends ChatListEvent {
  const ChatListFriendRequestCancelledEvent({
    required this.requestId,
    required this.from,
  });
  final String requestId;
  final ChatUser from;
}

/// `friend-request-declined` — pushed to the **original sender** when their
/// request is declined, so the outgoing tile disappears live (silent).
class ChatListFriendRequestDeclinedEvent extends ChatListEvent {
  const ChatListFriendRequestDeclinedEvent({
    required this.requestId,
    required this.from,
  });
  final String requestId;
  final ChatUser from;
}

/// `friend-removed` — pushed to the **removed** user when a friend deletes
/// them. `clerkId` is the remover (the other party), so the friend list can
/// be refreshed and a "X removed you as a friend" notice shown.
class ChatListFriendRemovedEvent extends ChatListEvent {
  const ChatListFriendRemovedEvent({required this.clerkId, this.username});
  final String clerkId;
  final String? username;
}

/// `dictionary-update` — pushed to chat members so they invalidate the
/// dictionary provider when another member saves changes.
class ChatListDictionaryUpdateEvent extends ChatListEvent {
  const ChatListDictionaryUpdateEvent({
    required this.chatId,
    required this.version,
  });
  final String chatId;
  final int version;
}
