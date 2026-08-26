import '../core/api_client.dart';
import '../models/chat.dart';
import '../models/json_utils.dart';
import 'json_lists.dart';
import 'package:flutter/foundation.dart';

/// Typed access to the backend chat endpoints (`/api/chats...`).
///
/// Note: message sending is NOT here — it goes over the chat WebSocket
/// (REST `POST /chats/:id/messages` returns ciphertext and doesn't
/// broadcast; see PLAN.md).
class ChatsRepository {
  ChatsRepository(this._api);

  final ApiClient _api;

  /// `GET /chats/all` — the chat list with last-message preview, unread
  /// counts and the group-vs-DM shapes.
  Future<List<ChatSummary>> getAll() async {
    final data = await _api.get('/chats/all');
    return asJsonList(data).map(ChatSummary.fromJson).toList();
  }

  /// `GET /chats/search?q=` — discover public/protected rooms to join.
  Future<List<ChatSearchResult>> search(String query) async {
    final data = await _api.get('/chats/search', query: {'q': query});
    return asJsonList(data).map(ChatSearchResult.fromJson).toList();
  }

  /// `POST /chats` — create a group room.
  Future<ChatSummary> createGroup({
    required String name,
    List<String> participantIds = const [],
    String access = 'public',
    String canSendMessages = 'everyone',
  }) async {
    final data = await _api.post(
      '/chats',
      body: {
        'name': name,
        'participantIds': participantIds,
        'access': access,
        'canSendMessages': canSendMessages,
      },
    );
    return ChatSummary.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  /// `POST /chats/dm/start` — create (or reuse) a DM with [clerkUserId];
  /// returns the chat id. The backend only allows this between friends.
  Future<String> startDm(String clerkUserId) async {
    try {
      final data = await _api.post(
        '/chats/dm/start',
        body: {'userId': clerkUserId},
      );
      return (data as Map<String, dynamic>)['chatId'] as String;
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        debugPrint('[dm] User attempted to DM $clerkUserId but they are not friends (403 Forbidden)');
      }
      rethrow;
    }
  }

  /// `POST /chats/:chatId/join` — join a public room.
  Future<void> join(String chatId) async {
    await _api.post('/chats/$chatId/join');
  }

  /// `POST /chats/:chatId/join-request` — request to join a protected room.
  Future<void> joinRequest(String chatId) async {
    await _api.post('/chats/$chatId/join-request');
  }

  /// `POST /chats/:chatId/leave` — leave a room.
  Future<void> leave(String chatId) async {
    await _api.delete('/chats/$chatId/leave');
  }

  /// `GET /chats/:chatId/info` — full room details: participants with
  /// roles, access policy and `myRelation` (the caller's own role).
  Future<RoomInfo> getInfo(String chatId) async {
    final data = await _api.get('/chats/$chatId/info');
    return RoomInfo.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  /// `POST /chats/:chatId/invite` — invite a user by username (admin only;
  /// the backend rejects direct chats and users already in the room).
  Future<void> invite(String chatId, String username) async {
    await _api.post('/chats/$chatId/invite', body: {'username': username});
  }

  /// `POST /chats/:chatId/invite-link` — generate a fresh invite link (admin
  /// only; direct chats are rejected). Returns the code + shareable URL.
  Future<InviteLink> createInviteLink(String chatId) async {
    final data = await _api.post('/chats/$chatId/invite-link');
    return InviteLink.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  /// `DELETE /chats/:chatId/invite-link` — revoke the current invite link
  /// (admin only); the code no longer resolves afterwards.
  Future<void> revokeInviteLink(String chatId) async {
    await _api.delete('/chats/$chatId/invite-link');
  }

  /// `GET /chats/invite/:code` — preview the room behind an invite code
  /// without joining it (any signed-in user).
  Future<ChatSearchResult> getInviteInfo(String code) async {
    final data = await _api.get('/chats/invite/${Uri.encodeComponent(code)}');
    return ChatSearchResult.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// `POST /chats/invite/:code/join` — join the room behind an invite code.
  /// Succeeds whether or not the user was already a member.
  Future<({String chatId, bool alreadyMember})> joinByCode(String code) async {
    final data = await _api.post(
      '/chats/invite/${Uri.encodeComponent(code)}/join',
    );
    final map = data is Map<String, dynamic> ? data : const {};
    return (
      chatId: asString(map['chatId']) ?? '',
      alreadyMember: asBool(map['alreadyMember']),
    );
  }

  /// `POST /chats/:chatId/kick` — remove a participant (admin only; the
  /// owner is protected server-side). The backend's body field is the
  /// misspelled `targettedUserId`.
  Future<void> kick(String chatId, String targetUserId) async {
    await _api.post(
      '/chats/$chatId/kick',
      body: {'targettedUserId': targetUserId},
    );
  }

  /// `PUT /chats/:chatId/members/:userId/mute` — admin-only mute.
  Future<void> muteMember(String chatId, String targetUserId, String duration) async {
    await _api.put('/chats/$chatId/members/$targetUserId/mute', body: {'duration': duration});
  }

  /// `DELETE /chats/:chatId/members/:userId/mute` — admin-only unmute.
  Future<void> unmuteMember(String chatId, String targetUserId) async {
    await _api.delete('/chats/$chatId/members/$targetUserId/mute');
  }

  /// `PUT /chats/:chatId/mute-me` — self-mute notifications for a duration
  /// (`8h`, `1d`, `1w`, `forever`; backend defaults to forever). Mute is
  /// notifications-only and never blocks reading or sending.
  Future<bool> muteSelf(String chatId, {String duration = 'forever'}) async {
    final data = await _api.put(
      '/chats/$chatId/mute-me',
      body: {'duration': duration},
    );
    return data is Map<String, dynamic> && data['mutedByUser'] == true;
  }

  /// `DELETE /chats/:id/mute-me` — unmute self.
  Future<bool> unmuteSelf(String chatId) async {
    final data = await _api.delete('/chats/$chatId/mute-me');
    return data is Map<String, dynamic> && data['mutedByUser'] == true;
  }

  /// `PUT /chats/:chatId/name` — rename a room (admin only). Returns the
  /// new name (the response echoes it back in `chat.name`) so the caller
  /// can pop it back to the room screen.
  Future<String> rename(String chatId, String name) async {
    final data = await _api.put('/chats/$chatId/name', body: {'name': name});
    final chat = data is Map<String, dynamic> ? data['chat'] : null;
    final renamed = chat is Map<String, dynamic>
        ? asString(chat['name'])
        : null;
    return renamed ?? name;
  }

  /// `PUT /chats/:chatId/access` — change access policy (admin only;
  /// `direct` is rejected server-side). Optional [inviteCode] regenerates
  /// the invite code for protected rooms.
  Future<void> updateAccess(
    String chatId,
    String access, {
    String? inviteCode,
  }) async {
    await _api.put(
      '/chats/$chatId/access',
      body: {'access': access, 'inviteCode': ?inviteCode},
    );
  }

  /// `PUT /chats/:chatId/members/:targetUserId/role` — promote/demote a
  /// member (owner only; [role] ∈ `admin` | `member`).
  Future<void> setRole(String chatId, String targetUserId, String role) async {
    await _api.put(
      '/chats/$chatId/members/$targetUserId/role',
      body: {'role': role},
    );
  }

  /// `PUT /chats/:chatId/canSendMessage` — toggle who may send:
  /// `everyone` | `admins` (admin only).
  Future<void> updateCanSendMessage(String chatId, String policy) async {
    await _api.put(
      '/chats/$chatId/canSendMessage',
      body: {'canSendMessages': policy},
    );
  }

  /// `PUT /chats/:chatId/picture` — set/change the room picture (admin
  /// only). Pass an empty [pictureUrl] to clear it.
  Future<void> updatePicture(String chatId, String pictureUrl) async {
    await _api.put('/chats/$chatId/picture', body: {'pictureUrl': pictureUrl});
  }

  /// `PUT /chats/:chatId/description` — set/change the room description
  /// (admin only). Pass an empty [description] to clear it.
  Future<void> updateDescription(String chatId, String description) async {
    await _api.put(
      '/chats/$chatId/description',
      body: {'description': description},
    );
  }

  /// Uploads raw image bytes through the shared Cloudinary `POST /upload`
  /// route and returns the resulting URL (for room/profile pictures).
  Future<String> uploadImageBytes(List<int> bytes, String filename) =>
      _api.uploadBytes(bytes: bytes, filename: filename);

  /// `GET /user/blocked` — list blocked users.
  Future<List<Map<String, dynamic>>> getBlocked() async {
    final data = await _api.get('/user/blocked');
    return asJsonList(data).cast<Map<String, dynamic>>();
  }
}
