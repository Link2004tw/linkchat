import 'json_utils.dart';
import 'user.dart';

/// A friend entry from `GET /user/friends`.
///
/// The backend auto-creates DM chats and returns a `dmChatId` per friend,
/// so opening a DM is a single tap — no extra endpoint call needed.
class Friend {
  const Friend({
    this.backendId,
    this.clerkId,
    required this.username,
    this.firstName,
    this.profileImageUrl,
    this.dmChatId,
  });

  final String? backendId;
  final String? clerkId;
  final String username;
  final String? firstName;
  final String? profileImageUrl;
  final String? dmChatId;

  String get displayName =>
      (firstName != null && firstName!.isNotEmpty) ? firstName! : username;

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
        backendId: asString(json['_id']),
        clerkId: asString(json['userId']) ?? asString(json['clerkId']),
        username: asString(json['username']) ?? 'Unknown',
        firstName: asString(json['firstName']),
        profileImageUrl: asString(json['profileImageUrl']) ??
            asString(json['imageUrl']),
        dmChatId: asString(json['dmChatId']),
      );

  ChatUser toChatUser() => ChatUser(
        backendId: backendId,
        clerkId: clerkId,
        username: username,
        firstName: firstName,
        profileImageUrl: profileImageUrl,
      );
}
