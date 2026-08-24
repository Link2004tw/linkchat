import 'content_types.dart';
import 'dictionary.dart';
import 'json_utils.dart';
import 'user.dart';
import '../services/dictionary_crypto.dart';

/// Sending state of an optimistic (client-side) message.
enum MessageStatus { pending, sent, failed }

/// A reader who has seen a message (read receipts). Only present on the
/// author's own messages; derived server-side from member read cursors.
/// [lastReadAt] is when the reader's cursor passed this message.
class SeenByUser {
  const SeenByUser({
    required this.userId,
    required this.username,
    this.lastReadAt,
  });

  final String userId;
  final String username;
  final DateTime? lastReadAt;

  factory SeenByUser.fromJson(Map<String, dynamic> json) => SeenByUser(
        userId: asString(json['userId']) ?? '',
        username: asString(json['username']) ?? '',
        lastReadAt: asDateTime(json['lastReadAt']),
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'lastReadAt': lastReadAt?.toIso8601String(),
      };
}

/// A member mentioned in a message (`@username`), resolved server-side.
class MentionUser {
  const MentionUser({required this.userId, required this.username});

  final String userId;
  final String username;

  factory MentionUser.fromJson(Map<String, dynamic> json) => MentionUser(
        userId: asString(json['userId']) ?? '',
        username: asString(json['username']) ?? '',
      );

  Map<String, dynamic> toJson() => {'userId': userId, 'username': username};
}

/// Provenance of a forwarded message: which chat + message it came from and
/// who authored the original. Set server-side when a message is copied into
/// another chat via the forward endpoint.
class ForwardedFrom {
  const ForwardedFrom({
    required this.chatId,
    required this.messageId,
    required this.authorId,
    this.username = '',
  });

  final String chatId;
  final String messageId;
  final String authorId;

  /// Username of the original author (for the "Forwarded from …" tag).
  final String username;

  factory ForwardedFrom.fromJson(Map<String, dynamic> json) => ForwardedFrom(
        chatId: asString(json['chatId']) ?? '',
        messageId: asString(json['messageId']) ?? '',
        authorId: asString(json['authorId']) ?? '',
        username: asString(json['username']) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'messageId': messageId,
        'authorId': authorId,
        'username': username,
      };
}

/// A single chat message, parsed from either transport:
///
/// **WebSocket** (`type: "message"`):
///   `messageId`, `content`, `author`, `createdAt` (epoch ms), `isEdited`,
///   `contentType`, `fileName`, `mimeType`, `fileSize`, `replyTo` (string id
///   or populated object), `caption`.
///
/// **REST** (`GET /chats/:id/messages`):
///   `_id`, `content`, `author`, `createdAt` (ISO string), `isEdited`,
///   `contentType`, `event`, `replyTo` (populated object), file fields.
///
/// System events (join/leave/kick/invite/room-update) travel as their own WS
/// types carrying `text` — see [ChatMessage.systemEvent] / `WsEvent`.
class ChatMessage {
  const ChatMessage({
    this.id,
    required this.content,
    this.author,
    this.createdAt,
    this.isEdited = false,
    this.contentType = 'text',
    this.event,
    this.replyToId,
    this.fileName,
    this.mimeType,
    this.fileSize,
    this.caption,
    this.pendingId,
    this.sendFailed = false,
    this.seenBy = const [],
    this.mentions = const [],
    this.mentionAll = false,
    this.forwardedFrom,
  });

  /// `messageId` (WS) or `_id` (REST).
  final String? id;

  final String content;

  final ChatUser? author;

  final DateTime? createdAt;

  final bool isEdited;

  /// text | image | file | video | system
  final String contentType;

  /// join | leave | kick | invite | room-update
  final String? event;

  /// Normalized from `replyTo`: a string id, or the `_id` of a populated object.
  final String? replyToId;

  final String? fileName;

  final String? mimeType;

  final int? fileSize;

  final String? caption;

  /// Client-side id of the optimistic copy of this message. The server echo
  /// (with the real [id]) replaces the optimistic entry via this field.
  final String? pendingId;

  /// True when the optimistic send failed (socket down) and the user can
  /// retry by tapping the bubble.
  final bool sendFailed;

  /// Readers who have seen this message (read receipts; own messages only).
  final List<SeenByUser> seenBy;

  /// Members mentioned in this message (`@username`), resolved server-side.
  final List<MentionUser> mentions;

  /// True when the content contained `@all`.
  final bool mentionAll;

  /// When set, this message was forwarded from another chat (server tags the
  /// original chat/message/author).
  final ForwardedFrom? forwardedFrom;

  /// True when this message mentions [myUserId] (via `@name` or `@all`).
  bool mentionsMe(String myUserId) =>
      mentionAll || mentions.any((m) => m.userId == myUserId);

  /// [seenBy] sorted by read time, oldest reader first (readers without a
  /// timestamp sort last). Deterministic: equal timestamps tiebreak by user
  /// id. The server already sends oldest-first; this normalizes the live
  /// event path too.
  List<SeenByUser> get seenByOldestFirst => [...seenBy]..sort((a, b) {
        final at = a.lastReadAt;
        final bt = b.lastReadAt;
        if (at == null && bt == null) return a.userId.compareTo(b.userId);
        if (at == null) return 1;
        if (bt == null) return -1;
        final cmp = at.compareTo(bt);
        return cmp != 0 ? cmp : a.userId.compareTo(b.userId);
      });

  /// pending | sent | failed — only meaningful for optimistic messages.
  MessageStatus get status {
    if (pendingId == null) return MessageStatus.sent;
    return sendFailed ? MessageStatus.failed : MessageStatus.pending;
  }

  bool get isSystem => contentType == 'system' || event != null;

  /// Returns a copy with updated [content] / [isEdited] (used for WS edit
  /// events; other fields are preserved). [clearPendingId] drops the
  /// optimistic id (used when a server echo replaces an optimistic bubble).
  ChatMessage copyWith({
    String? content,
    bool? isEdited,
    String? pendingId,
    bool clearPendingId = false,
    List<SeenByUser>? seenBy,
    List<MentionUser>? mentions,
    bool? mentionAll,
    ForwardedFrom? forwardedFrom,
    bool clearForwardedFrom = false,
  }) =>
      ChatMessage(
        id: id,
        content: content ?? this.content,
        author: author,
        createdAt: createdAt,
        isEdited: isEdited ?? this.isEdited,
        contentType: contentType,
        event: event,
        replyToId: replyToId,
        fileName: fileName,
        mimeType: mimeType,
        fileSize: fileSize,
        caption: caption,
        pendingId: clearPendingId ? null : (pendingId ?? this.pendingId),
        sendFailed: sendFailed,
        seenBy: seenBy ?? this.seenBy,
        mentions: mentions ?? this.mentions,
        mentionAll: mentionAll ?? this.mentionAll,
        forwardedFrom: clearForwardedFrom ? null : (forwardedFrom ?? this.forwardedFrom),
      );

  /// Parses a WS `type: "message"` broadcast or history entry.
  factory ChatMessage.fromWs(Map<String, dynamic> json) => ChatMessage(
        id: asString(json['messageId']) ?? asString(json['_id']),
        pendingId: asString(json['pendingId']),
        content: asString(json['content']) ?? '',
        author: json['author'] is Map<String, dynamic>
            ? ChatUser.fromJson(json['author'] as Map<String, dynamic>)
            : null,
        createdAt: asDateTime(json['createdAt']),
        isEdited: asBool(json['isEdited']),
        contentType: asString(json['contentType']) ?? 'text',
        event: asString(json['event']),
        replyToId: _replyToId(json['replyTo']),
        fileName: asString(json['fileName']),
        mimeType: asString(json['mimeType']),
        fileSize: asInt(json['fileSize']),
        caption: asString(json['caption']),
        seenBy: _seenBy(json['seenBy']),
        mentions: _mentions(json['mentions']),
        mentionAll: asBool(json['mentionAll']),
        forwardedFrom: _forwardedFrom(json['forwardedFrom']),
      );

  /// Parses a REST message document from `GET /chats/:id/messages`.
  factory ChatMessage.fromRest(Map<String, dynamic> json) => ChatMessage(
        id: asString(json['_id']),
        content: asString(json['content']) ?? '',
        author: json['author'] is Map<String, dynamic>
            ? ChatUser.fromJson(json['author'] as Map<String, dynamic>)
            : null,
        createdAt: asDateTime(json['createdAt']),
        isEdited: asBool(json['isEdited']),
        contentType: asString(json['contentType']) ?? 'text',
        event: asString(json['event']),
        replyToId: _replyToId(json['replyTo']),
        fileName: asString(json['fileName']),
        mimeType: asString(json['mimeType']),
        fileSize: asInt(json['fileSize']),
        caption: asString(json['caption']),
        seenBy: _seenBy(json['seenBy']),
        mentions: _mentions(json['mentions']),
        mentionAll: asBool(json['mentionAll']),
        forwardedFrom: _forwardedFrom(json['forwardedFrom']),
      );

  /// `replyTo` is a string id (WS history) or a populated object (REST/broadcast).
  static String? _replyToId(dynamic replyTo) {
    if (replyTo is String) return replyTo;
    if (replyTo is Map<String, dynamic>) return asString(replyTo['_id']);
    return null;
  }

  /// Serializes for local caching (mirrors the WS shape; id goes in both
  /// `_id` and `messageId` so either parser can read it back).
  Map<String, dynamic> toJson() => {
        '_id': id,
        'messageId': id,
        'content': content,
        'author': author?.toJson(),
        'createdAt': createdAt?.toIso8601String(),
        'isEdited': isEdited,
        'contentType': contentType,
        'event': event,
        'replyTo': replyToId,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'caption': caption,
        'pendingId': pendingId,
        'sendFailed': sendFailed,
        'seenBy': [for (final s in seenBy) s.toJson()],
        'mentions': [for (final m in mentions) m.toJson()],
        'mentionAll': mentionAll,
        'forwardedFrom': forwardedFrom?.toJson(),
      };

  static List<SeenByUser> _seenBy(dynamic json) {
    if (json is! List) return const [];
    return json
        .whereType<Map<String, dynamic>>()
        .map(SeenByUser.fromJson)
        .toList();
  }

  static List<MentionUser> _mentions(dynamic json) {
    if (json is! List) return const [];
    return json
        .whereType<Map<String, dynamic>>()
        .map(MentionUser.fromJson)
        .toList();
  }

  static ForwardedFrom? _forwardedFrom(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    return ForwardedFrom.fromJson(json);
  }
}

/// The text to put on the clipboard when a message is copied:
/// - text: the content with every code word expanded to its meaning (copies
///   what you see when the bubble is revealed), or the raw content when the
///   chat has no dictionary;
/// - media (image/video/file/audio): the caption when present, else the raw
///   media URL.
///
/// This is a pure client-side transform — nothing is sent to the server.
String messageCopyText(ChatMessage message, List<DictEntry> entries) {
  String expand(String text) => entries.isEmpty
      ? text
      : DictionaryCrypto.expandIncoming(text, entries);
  switch (message.contentType) {
    case ContentTypes.image:
    case ContentTypes.video:
    case ContentTypes.file:
    case ContentTypes.audio:
      final caption = message.caption;
      if (caption != null && caption.isNotEmpty) return expand(caption);
      return message.content;
    default:
      return expand(message.content);
  }
}

/// Paginated response of `GET /chats/:id/messages?limit&before`.
class MessagePage {
  const MessagePage({
    required this.messages,
    this.name,
    this.more = false,
    this.nextCursor,
    this.canSendMessages = 'everyone',
    this.isDm = false,
  });

  /// Chronological (oldest → newest).
  final List<ChatMessage> messages;

  final String? name;

  final bool more;

  /// Pass as `before` to fetch older messages.
  final String? nextCursor;

  /// everyone | admins — whether the current user may send.
  final String canSendMessages;

  final bool isDm;

  factory MessagePage.fromJson(Map<String, dynamic> json) => MessagePage(
        messages: json['messages'] is List
            ? (json['messages'] as List)
                .whereType<Map<String, dynamic>>()
                .map(ChatMessage.fromRest)
                .toList()
            : const [],
        name: asString(json['name']),
        more: asBool(json['more']),
        nextCursor: asString(json['nextCursor']),
        canSendMessages: asString(json['canSendMessages']) ?? 'everyone',
        isDm: asBool(json['isDm']),
      );
}
