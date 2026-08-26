import '../core/api_client.dart';
import '../models/user.dart';
import 'json_lists.dart';

/// Typed access to user endpoints (`/api/user...`).
class UserRepository {
  UserRepository(this._api);

  final ApiClient _api;

  /// `GET /user/search?q=` — global user search. Results include
  /// `friendRequestStatus` (friends | pending | respond | none) so screens
  /// can render the right action button.
  Future<List<UserSearchResult>> searchUsers(String query, {int limit = 5}) async {
    final data = await _api.get('/user/search', query: {
      'q': query,
      'limit': '$limit',
    });
    return asJsonList(data).map(UserSearchResult.fromJson).toList();
  }

  /// `GET /user/:clerkId` — one user's public profile with the caller's
  /// relationship to them (friend status, DM id, shared rooms). Throws a
  /// 404 [ApiException] when the target has blocked the caller.
  Future<UserSearchResult> getUser(String clerkId) async {
    final data = await _api.get('/user/${Uri.encodeComponent(clerkId)}');
    return UserSearchResult.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// `PATCH /user/profile` — update the caller's own profile (username,
  /// display name, avatar URL). Username conflicts surface as
  /// [ApiException] with 409. Pass `profileImageUrl` as an empty string to
  /// clear the avatar.
  Future<ChatUser> updateProfile({
    String? username,
    String? firstName,
    String? profileImageUrl,
  }) async {
    final data = await _api.patch('/user/profile', body: {
      'username': ?username,
      'firstName': ?firstName,
      'profileImageUrl': ?profileImageUrl,
    });
    return ChatUser.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  // ── Blocking (spec §14) ───────────────────────────────────────────────

  /// `GET /user/blocked` → clerk ids the caller has blocked.
  Future<Set<String>> getBlocked() async {
    final data = await _api.get('/user/blocked');
    if (data is! List) return const {};
    return {
      for (final entry in data)
        if (entry is Map && entry['clerkId'] is String) entry['clerkId'] as String,
    };
  }

  /// `PUT /user/blocked/:clerkId` — block a user (idempotent).
  Future<void> blockUser(String clerkId) async {
    await _api.put('/user/blocked/${Uri.encodeComponent(clerkId)}');
  }

  /// `DELETE /user/blocked/:clerkId` — unblock a user (idempotent).
  Future<void> unblockUser(String clerkId) async {
    await _api.delete('/user/blocked/${Uri.encodeComponent(clerkId)}');
  }
}
