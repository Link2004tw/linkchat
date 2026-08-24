import '../core/api_client.dart';
import '../models/message.dart';

/// Typed access to message history (`GET /chats/:id/messages`).
///
/// Used for initial load and scroll-up pagination. Live messages come from
/// the chat WebSocket instead.
class MessagesRepository {
  MessagesRepository(this._api);

  final ApiClient _api;

  /// Fetches a page of messages (oldest → newest). Pass [before] (the
  /// `nextCursor` of the previous page) to fetch older messages.
  Future<MessagePage> getMessages(
    String chatId, {
    int limit = 50,
    String? before,
  }) async {
    final data = await _api.get('/chats/$chatId/messages', query: {
      'limit': '$limit',
      'before': ?before,
    });
    return MessagePage.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// `POST /chats/:chatId/messages/:messageId/delete-for-me` — hides the
  /// message from this user's own history (no broadcast to others).
  Future<void> deleteForMe(String chatId, String messageId) async {
    await _api.post('/chats/$chatId/messages/$messageId/delete-for-me');
  }

  /// `POST /chats/:chatId/messages/:messageId/forward` — copies a message
  /// from [sourceChatId] into [targetChatId] as a NEW message by the caller,
  /// tagged with the original chat/message/author (`forwardedFrom`).
  Future<ChatMessage> forward({
    required String sourceChatId,
    required String messageId,
    required String targetChatId,
  }) async {
    final data = await _api.post(
      '/chats/$sourceChatId/messages/$messageId/forward',
      body: {'targetChatId': targetChatId},
    );
    return ChatMessage.fromRest(data is Map<String, dynamic> ? data : const {});
  }
}
