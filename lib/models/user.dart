import 'json_utils.dart';

/// A user as returned by the backend.
///
/// Field-name normalization:
///   - Avatar: `profileImageUrl` (WS broadcasts, `/chats/all`) vs
///     `imageUrl` (`/user/search`, `/user/:clerkId`, DM `otherUser`).
///   - ID: `userId`/`clerkId` is the Clerk ID; `_id` is the backend's
///     internal id (the Clerk ID again for users, post-Firestore-cutover).
class ChatUser {
  const ChatUser({
    this.backendId,
    this.clerkId,
    required this.username,
    this.firstName,
    this.profileImageUrl,
  });

  /// Backend `_id` (present on WS authors, friends, populated users).
  final String? backendId;

  /// Clerk user ID — `userId` on WS, `clerkId` on `/user` endpoints.
  final String? clerkId;

  final String username;

  final String? firstName;

  /// Normalized from `profileImageUrl` or `imageUrl`.
  final String? profileImageUrl;

  String get displayName =>
      (firstName != null && firstName!.isNotEmpty) ? firstName! : username;

  factory ChatUser.fromJson(Map<String, dynamic> json) => ChatUser(
        backendId: asString(json['_id']),
        clerkId: asString(json['userId']) ?? asString(json['clerkId']),
        username: asString(json['username']) ?? asString(json['name']) ?? 'Unknown',
        // `/user/search` sends the display name as `name` (firstName ||
        // username); other endpoints send `firstName`.
        firstName: asString(json['firstName']) ?? asString(json['name']),
        profileImageUrl: asString(json['profileImageUrl']) ??
            asString(json['imageUrl']),
      );

  Map<String, dynamic> toJson() => {
        if (backendId != null) '_id': backendId,
        if (clerkId != null) 'userId': clerkId,
        'username': username,
        if (firstName != null) 'firstName': firstName,
        if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
      };
}

/// Result of `GET /user/search?q=` or `GET /user/:clerkId`.
///
/// `friendRequestStatus` is one of: `friends` | `pending` | `respond` | `none`.
class UserSearchResult {
  const UserSearchResult({
    required this.user,
    this.friendRequestStatus,
    this.friendRequestId,
    this.dmId,
    this.sharedRoomsCount,
  });

  final ChatUser user;

  /// friends | pending (I sent) | respond (they sent) | none
  final String? friendRequestStatus;

  final String? friendRequestId;

  /// Present on `/user/:clerkId` when already friends.
  final String? dmId;

  final int? sharedRoomsCount;

  bool get isFriend => friendRequestStatus == 'friends';

  factory UserSearchResult.fromJson(Map<String, dynamic> json) =>
      UserSearchResult(
        user: ChatUser.fromJson(json),
        friendRequestStatus: asString(json['friendRequestStatus']),
        friendRequestId: asString(json['friendRequestId']),
        dmId: asString(json['dmId']),
        sharedRoomsCount: asInt(json['sharedRoomsCount']),
      );
}
