import 'content_types.dart';
import 'json_utils.dart';

/// Last-message preview from `GET /chats/all`.
///
/// Note: the backend's `senderId` field actually carries the sender's
/// **username**, so it is exposed as [senderName].
class ChatLastMessage {
  const ChatLastMessage({
    required this.content,
    this.sentAt,
    this.senderName,
    this.contentType,
    this.mediaUrl,
  });

  /// Preview text: the message text, the caption for media, or a short
  /// label for caption-less media (never the raw upload URL).
  final String content;
  final DateTime? sentAt;
  final String? senderName;

  /// text | image | file | video | system — null for legacy cached payloads.
  final String? contentType;

  /// Raw media URL (image/video/file), used to render a thumbnail in the
  /// chat list. Null for text/system messages and legacy payloads.
  final String? mediaUrl;

  /// Text shown in the chat-list tile. Media with no caption (or legacy
  /// payloads that stored the raw upload URL as [content]) falls back to a
  /// short label so the preview is never blank.
  String get previewText {
    final trimmed = content.trim();
    final isMedia = isMediaContentType(contentType);
    if (isMedia) {
      if (trimmed.isEmpty) return _mediaLabel(contentType!);
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.hasScheme) return _mediaLabel(contentType!);
    }
    return trimmed.isEmpty ? 'New message' : trimmed;
  }

  static String _mediaLabel(String type) => switch (type) {
    ContentTypes.image => '📷 Photo',
    ContentTypes.video => '🎬 Video',
    ContentTypes.audio => '🎵 Audio',
    ContentTypes.file => '📎 File',
    _ => '📎 Attachment',
  };

  factory ChatLastMessage.fromJson(Map<String, dynamic> json) =>
      ChatLastMessage(
        content: asString(json['content']) ?? '',
        sentAt: asDateTime(json['sentAt']),
        senderName: asString(json['senderId']) ?? asString(json['senderName']),
        contentType: asString(json['contentType']),
        mediaUrl: asString(json['mediaUrl']),
      );

  Map<String, dynamic> toJson() => {
    'content': content,
    'sentAt': sentAt?.toIso8601String(),
    'senderId': senderName,
    'contentType': contentType,
    'mediaUrl': mediaUrl,
  };
}

/// The other participant of a direct-message chat (from `/chats/all`).
class ChatOtherUser {
  const ChatOtherUser({this.clerkId, this.name, this.imageUrl});

  final String? clerkId;
  final String? name;
  final String? imageUrl;

  factory ChatOtherUser.fromJson(Map<String, dynamic> json) => ChatOtherUser(
    clerkId: asString(json['clerkId']),
    name: asString(json['name']),
    imageUrl: asString(json['imageUrl']),
  );

  Map<String, dynamic> toJson() => {
    'clerkId': clerkId,
    'name': name,
    'imageUrl': imageUrl,
  };
}

/// One entry of the chat list (`GET /chats/all`).
///
/// The backend returns two shapes: group chats carry `participantCount` +
/// `previewMembers`; direct chats carry `otherUser` instead. Both are
/// modeled here with nullable fields.
class ChatSummary {
  const ChatSummary({
    required this.id,
    this.name,
    required this.access,
    this.unreadCount = 0,
    this.mentionedCount = 0,
    this.updatedAt,
    this.lastMessage,
    this.participantCount,
    this.previewMembers = const [],
    this.otherUser,
    this.pictureUrl,
  });

  final String id;

  /// Null for direct chats (they have no name).
  final String? name;

  /// direct | public | protected | private
  final String access;

  final int unreadCount;

  /// Unread messages that mention me (`@name` / `@all`) — drives the
  /// "mentioned" badge on the chat list.
  final int mentionedCount;

  final DateTime? updatedAt;

  final ChatLastMessage? lastMessage;

  final int? participantCount;

  final List<String> previewMembers;

  final ChatOtherUser? otherUser;

  /// Group-room picture (Cloudinary URL). Direct chats always render the
  /// partner's profile picture instead.
  final String? pictureUrl;

  /// Returns a copy with the given fields replaced (used for live list
  /// updates from the chat-list WebSocket).
  ChatSummary copyWith({
    String? name,
    String? access,
    int? unreadCount,
    int? mentionedCount,
    DateTime? updatedAt,
    ChatLastMessage? lastMessage,
    String? pictureUrl,
  }) => ChatSummary(
    id: id,
    name: name ?? this.name,
    access: access ?? this.access,
    unreadCount: unreadCount ?? this.unreadCount,
    mentionedCount: mentionedCount ?? this.mentionedCount,
    updatedAt: updatedAt ?? this.updatedAt,
    lastMessage: lastMessage ?? this.lastMessage,
    participantCount: participantCount,
    previewMembers: previewMembers,
    otherUser: otherUser,
    pictureUrl: pictureUrl ?? this.pictureUrl,
  );

  bool get isDm => access == 'direct';

  String get displayName {
    final other = otherUser?.name;
    if (other != null && other.isNotEmpty) return other;
    if (name != null && name!.isNotEmpty) return name!;
    final members = previewMembers.take(3).join(', ');
    return members.isNotEmpty ? members : 'Chat';
  }

  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
    id: asString(json['_id']) ?? '',
    name: asString(json['name']),
    access: asString(json['access']) ?? 'public',
    unreadCount: asInt(json['unreadCount']) ?? 0,
    mentionedCount: asInt(json['mentionedCount']) ?? 0,
    updatedAt: asDateTime(json['updatedAt']),
    lastMessage: json['lastMessage'] is Map<String, dynamic>
        ? ChatLastMessage.fromJson(json['lastMessage'] as Map<String, dynamic>)
        : null,
    participantCount: asInt(json['participantCount']),
    previewMembers: json['previewMembers'] is List
        ? (json['previewMembers'] as List)
              .map((e) => asString(e) ?? '')
              .toList()
        : const [],
    otherUser: json['otherUser'] is Map<String, dynamic>
        ? ChatOtherUser.fromJson(json['otherUser'] as Map<String, dynamic>)
        : null,
    pictureUrl: asString(json['pictureUrl']),
  );

  /// Serializes for local caching.
  Map<String, dynamic> toJson() => {
    '_id': id,
    'name': name,
    'access': access,
    'unreadCount': unreadCount,
    'mentionedCount': mentionedCount,
    'updatedAt': updatedAt?.toIso8601String(),
    'lastMessage': lastMessage?.toJson(),
    'participantCount': participantCount,
    'previewMembers': previewMembers,
    'otherUser': otherUser?.toJson(),
    'pictureUrl': pictureUrl,
  };
}

/// One result of `GET /chats/search?q=` — public/protected rooms to join.
class ChatSearchResult {
  const ChatSearchResult({
    required this.chatId,
    this.name,
    this.access,
    this.participantCount,
    this.isRequested,
  });

  final String chatId;
  final String? name;

  /// public | protected
  final String? access;

  final int? participantCount;

  /// Present (and true) when the current user already requested to join a
  /// protected room.
  final bool? isRequested;

  factory ChatSearchResult.fromJson(Map<String, dynamic> json) =>
      ChatSearchResult(
        chatId: asString(json['chatId']) ?? asString(json['_id']) ?? '',
        name: asString(json['name']),
        access: asString(json['access']),
        participantCount: asInt(json['participantCount']),
        isRequested: json['isRequested'] == null
            ? null
            : asBool(json['isRequested']),
      );
}

/// The response of `POST /chats/:id/invite-link`: the generated code and the
/// full shareable URL (deep link or fallback `chatapp://join/<code>`).
class InviteLink {
  const InviteLink({
    required this.code,
    required this.url,
    this.chatId,
    this.inviteCode,
  });

  /// The raw invite code (pasteable into JoinInviteScreen).
  final String code;

  /// The shareable link; the code is always recoverable from it, so copying
  /// the URL works for every recipient regardless of deep-link support.
  final String url;

  final String? chatId;

  /// Backend alias of [code].
  final String? inviteCode;

  factory InviteLink.fromJson(Map<String, dynamic> json) => InviteLink(
    code: asString(json['code']) ?? asString(json['inviteCode']) ?? '',
    url: asString(json['url']) ?? '',
    chatId: asString(json['chatId']),
    inviteCode: asString(json['inviteCode']),
  );
}

/// One participant of a room, from `GET /chats/:id/info`.
///
/// The backend nests the user under `participants[].user` with `_id`/
/// `userId` (both the Clerk ID), `username`, `profileImageUrl`; the role
/// (`owner | admin | member | guest`) sits next to it.
class RoomParticipant {
  const RoomParticipant({
    required this.clerkId,
    required this.username,
    this.profileImageUrl,
    required this.role,
    this.mutedUntil,
    this.mutedByUser = false,
  });

  final String clerkId;
  final String username;
  final String? profileImageUrl;

  /// owner | admin | member | guest
  final String role;

  final String? mutedUntil;
  final bool mutedByUser;

  bool get isAdmin => role == 'owner' || role == 'admin';

  bool get isMutedNow =>
      mutedUntil != null &&
      DateTime.tryParse(mutedUntil!)?.isAfter(DateTime.now()) == true;

  factory RoomParticipant.fromJson(Map<String, dynamic> json) {
    final user = json['user'] is Map<String, dynamic>
        ? json['user'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return RoomParticipant(
      clerkId: asString(user['userId']) ?? asString(user['_id']) ?? '',
      username: asString(user['username']) ?? 'Unknown',
      profileImageUrl: asString(user['profileImageUrl']),
      role: asString(json['role']) ?? 'member',
      mutedUntil: asString(json['mutedUntil']),
      mutedByUser: json['mutedByUser'] == true,
    );
  }
}

/// Room details from `GET /chats/:id/info`.
///
/// The response is the chat view spread with a top-level `myRelation` (my
/// role in the room: owner | admin | member | guest) and `participants`.
/// Admins also get `requests` (join requests), which this model ignores.
class RoomInfo {
  const RoomInfo({
    required this.id,
    this.name,
    this.description = '',
    required this.access,
    this.canSendMessages = 'everyone',
    this.createdBy,
    this.inviteCode,
    this.myRelation,
    this.participants = const [],
    this.pictureUrl,
  });

  final String id;

  /// Null for direct chats (they have no name).
  final String? name;

  /// Free-text room description (set/edited by admins in RoomDetails).
  final String description;

  /// direct | public | protected | private
  final String access;

  /// everyone | admins
  final String canSendMessages;

  /// Clerk ID of the creator.
  final String? createdBy;

  final String? inviteCode;

  /// Group-room picture (Cloudinary URL).
  final String? pictureUrl;

  /// My role in this room: owner | admin | member | guest.
  final String? myRelation;

  final List<RoomParticipant> participants;

  bool get isDm => access == 'direct';

  /// Whether I can administer the room (rename, access, can-send policy,
  /// kick, invite).
  bool get isAdmin => myRelation == 'owner' || myRelation == 'admin';

  factory RoomInfo.fromJson(Map<String, dynamic> json) => RoomInfo(
    id: asString(json['_id']) ?? '',
    name: asString(json['name']),
    description: asString(json['description']) ?? '',
    access: asString(json['access']) ?? 'public',
    canSendMessages: asString(json['canSendMessages']) ?? 'everyone',
    createdBy: asString(json['createdBy']),
    inviteCode: asString(json['inviteCode']),
    pictureUrl: asString(json['pictureUrl']),
    myRelation: asString(json['myRelation']),
    participants: json['participants'] is List
        ? (json['participants'] as List)
              .whereType<Map<String, dynamic>>()
              .map(RoomParticipant.fromJson)
              .toList()
        : const [],
  );
}
