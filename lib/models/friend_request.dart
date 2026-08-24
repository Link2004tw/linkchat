import 'json_utils.dart';
import 'user.dart';

/// One friend request from `GET /user/friends/requests`.
///
/// The backend returns two lists (`ingoing` = requests sent to me,
/// `outgoing` = requests I sent) with the `from`/`to` users populated.
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.from,
    required this.to,
    this.status = 'pending',
    this.message,
    this.createdAt,
  });

  final String id;

  /// The sender (populated user).
  final ChatUser from;

  /// The recipient (populated user).
  final ChatUser to;

  /// pending | accepted | declined
  final String status;

  final String? message;

  final DateTime? createdAt;

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
        id: asString(json['_id']) ?? '',
        from: json['from'] is Map<String, dynamic>
            ? ChatUser.fromJson(json['from'] as Map<String, dynamic>)
            : const ChatUser(username: 'Unknown'),
        to: json['to'] is Map<String, dynamic>
            ? ChatUser.fromJson(json['to'] as Map<String, dynamic>)
            : const ChatUser(username: 'Unknown'),
        status: asString(json['status']) ?? 'pending',
        message: asString(json['message']),
        createdAt: asDateTime(json['createdAt']),
      );
}

/// Response of `GET /user/friends/requests`.
class FriendRequests {
  const FriendRequests({this.ingoing = const [], this.outgoing = const []});

  final List<FriendRequest> ingoing;
  final List<FriendRequest> outgoing;

  factory FriendRequests.fromJson(Map<String, dynamic> json) => FriendRequests(
        ingoing: _parseList(json['ingoingRequests']),
        outgoing: _parseList(json['outgoingRequests']),
      );

  static List<FriendRequest> _parseList(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map<String, dynamic>>()
        .map(FriendRequest.fromJson)
        .toList();
  }
}
