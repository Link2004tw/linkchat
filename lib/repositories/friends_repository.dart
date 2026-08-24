import '../core/api_client.dart';
import '../models/friend.dart';
import '../models/friend_request.dart';
import '../models/json_utils.dart';
import 'json_lists.dart';
import 'package:flutter/foundation.dart';

/// Typed access to the friends endpoints (`/api/user/friends...`).
class FriendsRepository {
  FriendsRepository(this._api);

  final ApiClient _api;

  /// `GET /user/friends` — friends list. Each friend includes a `dmChatId`
  /// (the backend auto-creates DM chats), so opening a DM is one tap.
  Future<List<Friend>> getFriends() async {
    final data = await _api.get('/user/friends');
    return asJsonList(data).map(Friend.fromJson).toList();
  }

  /// `POST /user/friends` — send a friend request; returns the request id.
  Future<String> sendRequest(String targetClerkId) async {
    try {
      final data = await _api.post('/user/friends', body: {
        'targetClerkId': targetClerkId,
      });
      return (data as Map<String, dynamic>)['requestId'] as String;
    } on ApiException catch (e) {
      if (e.statusCode == 400 && e.message.contains('Already friends')) {
        debugPrint('[friend-request] Attempted to send friend request to $targetClerkId but already friends');
      } else if (e.statusCode == 409) {
        debugPrint('[friend-request] Attempted to send friend request to $targetClerkId but one is already pending');
      } else if (e.statusCode == 400 && e.message.contains('yourself')) {
        debugPrint('[friend-request] Attempted to send a friend request to self');
      }
      rethrow;
    }
  }

  /// `GET /user/friends/requests` — pending incoming + outgoing requests.
  Future<FriendRequests> getRequests() async {
    final data = await _api.get('/user/friends/requests');
    return FriendRequests.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// `PUT /user/friends/requests/:id/accept` — accept an incoming request.
  Future<void> acceptRequest(String requestId) async {
    try {
      await _api.put('/user/friends/requests/$requestId/accept');
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        debugPrint('[friend-request] Attempted to accept request $requestId but is not authorized');
      } else if (e.statusCode == 400 && e.message.contains('already processed')) {
        debugPrint('[friend-request] Attempted to accept request $requestId but it was already processed');
      } else if (e.statusCode == 404) {
        debugPrint('[friend-request] Attempted to accept request $requestId but it was not found');
      }
      rethrow;
    }
  }

  /// `PUT /user/friends/requests/:id/decline` — decline an incoming request.
  Future<void> declineRequest(String requestId) async {
    try {
      await _api.put('/user/friends/requests/$requestId/decline');
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        debugPrint('[friend-request] Attempted to decline request $requestId but is not authorized');
      } else if (e.statusCode == 400 && e.message.contains('already processed')) {
        debugPrint('[friend-request] Attempted to decline request $requestId but it was already processed');
      } else if (e.statusCode == 404) {
        debugPrint('[friend-request] Attempted to decline request $requestId but it was not found');
      }
      rethrow;
    }
  }

  /// `DELETE /user/friends/requests/:id` — cancel an outgoing request.
  Future<void> cancelRequest(String requestId) async {
    try {
      await _api.delete('/user/friends/requests/$requestId');
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        debugPrint('[friend-request] Attempted to cancel request $requestId but is not the sender');
      } else if (e.statusCode == 400 && e.message.contains('already processed')) {
        debugPrint('[friend-request] Attempted to cancel request $requestId but it was already processed');
      } else if (e.statusCode == 404) {
        debugPrint('[friend-request] Attempted to cancel request $requestId but it was not found');
      }
      rethrow;
    }
  }

  /// `DELETE /user/friends/:clerkId` — remove a friend.
  Future<void> removeFriend(String clerkId) async {
    await _api.delete('/user/friends/$clerkId');
  }

  /// `GET /user/friends/:clerkId/dm` — resolve the DM chat id for a friend.
  /// Returns null if not friends or on error.
  Future<String?> getFriendDm(String clerkId) async {
    try {
      final data = await _api.get('/user/friends/$clerkId/dm');
      return (data is Map<String, dynamic>) ? asString(data['dmChatId']) : null;
    } on ApiException catch (e) {
      if (e.statusCode == 403 || e.statusCode == 404) {
        debugPrint('[dm] Could not resolve DM for $clerkId — not friends or user not found (${e.statusCode})');
      }
      return null;
    } on Exception {
      return null;
    }
  }
}
