import '../models/message.dart';
import '../models/user.dart';
import '../models/ws_event.dart';

/// Client-side cap for uploads (the server allows 10 MB).
const int maxUploadBytesLimit = 6 * 1024 * 1024;

/// The server replays at most this many messages as WS history on connect
/// (see `getMessages(chatId, 50, …)` in the backend) with no cursor, so a
/// batch shorter than this means there is no older history to page into.
const int _wsHistoryCap = 50;

/// A single in-flight file upload (progress 0–100).
class UploadProgress {
  const UploadProgress({required this.name, required this.progress});

  final String name;
  final int progress;

  UploadProgress copyWith({int? progress}) =>
      UploadProgress(name: name, progress: progress ?? this.progress);
}

/// Why an upload was rejected before any bytes were sent. Each value carries
/// a user-facing reason so the UI never shows a vague "could not send file".
enum UploadFailure {
  notConnected('Not connected to the server'),
  empty('The file is empty'),
  tooLarge(
    'File too large (max ${maxUploadBytesLimit ~/ (1024 * 1024)} MB)',
  ),
  busy('Another upload is still in progress');

  const UploadFailure(this.message);
  final String message;
}

/// State of one open chat room, fed by the `/ws/chat` socket.
/// A member's read-receipt cursor (who read up to where), from `read`
/// broadcasts. Rendered under own messages as "Seen by …".
class ReadCursor {
  const ReadCursor({required this.username, this.lastReadAt});

  final String username;
  final DateTime? lastReadAt;
}

class ChatRoomState {
  const ChatRoomState({
    this.messages = const [],
    this.onlineUsers = const {},
    this.typingUserIds = const {},
    this.uploads = const {},
    this.isConnected = false,
    this.isLoading = true,
    this.lastError,
    this.uploadError,
    this.hasMoreHistory = true,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.historyCursor,
    this.reconnectAttempts = 0,
    this.connectionError,
    this.readCursors = const {},
  });

  /// Chronological (oldest → newest). Includes system rows.
  final List<ChatMessage> messages;

  /// userId → user, for presence (online dots, member count).
  final Map<String, ChatUser> onlineUsers;

  /// userIds currently typing (auto-expired after ~3s).
  final Set<String> typingUserIds;

  /// uploadId → progress, for in-flight file uploads.
  final Map<String, UploadProgress> uploads;

  final bool isConnected;

  /// True until the server finishes sending history (the `Welcome!`
  /// system message marks the end of it).
  final bool isLoading;

  final String? lastError;

  /// The reason the most recent upload failed (server rejection, lost
  /// connection, …). Consumed by the room screen to show a snackbar, then
  /// cleared so it doesn't nag repeatedly.
  final String? uploadError;

  // ── Pagination (task 14) ────────────────────────────────────────────

  /// False once the server reports no more history (`more: false`).
  final bool hasMoreHistory;

  final bool isLoadingMore;

  /// Set when a load-older fetch fails (shown as a snackbar/row).
  final String? loadMoreError;

  /// Passed as `before` for the next page. The initial value is the oldest
  /// WS-history message id; afterwards it's the page's `nextCursor`.
  final String? historyCursor;

  /// Consecutive failed reconnects (0 while connected). Shown in the UI.
  final int reconnectAttempts;

  /// The last WebSocket connection failure (error + redacted URL), shown in
  /// the room's reconnect banner. Cleared once the socket reconnects.
  final String? connectionError;

  /// userId → read cursor for live `read` broadcasts (read receipts).
  final Map<String, ReadCursor> readCursors;

  ChatRoomState copyWith({
    List<ChatMessage>? messages,
    Map<String, ChatUser>? onlineUsers,
    Set<String>? typingUserIds,
    Map<String, UploadProgress>? uploads,
    bool? isConnected,
    bool? isLoading,
    String? lastError,
    bool clearError = false,
    String? uploadError,
    bool clearUploadError = false,
    bool? hasMoreHistory,
    bool? isLoadingMore,
    String? loadMoreError,
    String? historyCursor,
    int? reconnectAttempts,
    String? connectionError,
    bool clearConnectionError = false,
    bool clearLoadMoreError = false,
    Map<String, ReadCursor>? readCursors,
  }) => ChatRoomState(
    messages: messages ?? this.messages,
    onlineUsers: onlineUsers ?? this.onlineUsers,
    typingUserIds: typingUserIds ?? this.typingUserIds,
    uploads: uploads ?? this.uploads,
    isConnected: isConnected ?? this.isConnected,
    isLoading: isLoading ?? this.isLoading,
    lastError: clearError ? null : (lastError ?? this.lastError),
    uploadError: clearUploadError ? null : (uploadError ?? this.uploadError),
    hasMoreHistory: hasMoreHistory ?? this.hasMoreHistory,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    loadMoreError: clearLoadMoreError
        ? null
        : (loadMoreError ?? this.loadMoreError),
    historyCursor: historyCursor ?? this.historyCursor,
    reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
    connectionError: clearConnectionError
        ? null
        : (connectionError ?? this.connectionError),
    readCursors: readCursors ?? this.readCursors,
  );
}

/// Applies a chat WebSocket event to the room state. Pure, so it can be
/// unit tested without Riverpod or a socket.
ChatRoomState applyChatEvent(
  ChatRoomState state,
  WsEvent event, {
  /// The current user's Clerk id — used to attach read-receipts only to
  /// messages this user authored (mirrors the server's sender-only rule).
  /// Null skips the seenBy attachment (cursor still updates).
  String? myUserId,
}) {
  switch (event) {
    case WsMessageEvent():
      return state.copyWith(
        messages: _upsertMessage(state.messages, event.message),
        onlineUsers: _rememberAvatar(state.onlineUsers, event.message.author),
      );

    case WsEditEvent():
      return state.copyWith(
        messages: [
          for (final m in state.messages)
            if (m.id == event.messageId)
              m.copyWith(
                content: event.content,
                isEdited: true,
                mentions: event.mentions,
                mentionAll: event.mentionAll,
              )
            else
              m,
        ],
      );

    case WsDeleteEvent():
      return state.copyWith(
        messages: [
          for (final m in state.messages)
            if (m.id != event.messageId) m,
        ],
      );

    case WsPresenceEvent():
      final next = Map<String, ChatUser>.of(state.onlineUsers);
      if (event.isOnline) {
        // The presence broadcast only carries userId + username; keep any
        // avatar URL we already learned from this user's messages.
        final existing = next[event.userId];
        next[event.userId] = ChatUser(
          clerkId: event.userId,
          username: event.username,
          profileImageUrl: existing?.profileImageUrl,
        );
      } else {
        next.remove(event.userId);
      }
      return state.copyWith(onlineUsers: next);

    case WsTypingEvent():
      return state.copyWith(
        typingUserIds: {...state.typingUserIds, event.userId},
      );

    case WsSystemEvent():
      // The server sends `{type: "system", text: "Welcome!"}` right after
      // the history — that marks history complete for this client. It's a
      // marker only: the Welcome row itself is not rendered.
      final historyDone = event.type == 'system';
      final messages = historyDone
          // After a reconnect the server replays the full history, so any
          // optimistic entry that never got an echo is dropped — if it did
          // send, it's back in the history.
          ? [
              for (final m in state.messages)
                if (m.pendingId == null || m.sendFailed) m,
            ]
          : state.messages;
      return state.copyWith(
        isLoading: historyDone ? false : state.isLoading,
        isConnected: historyDone ? true : state.isConnected,
        reconnectAttempts: historyDone ? 0 : state.reconnectAttempts,
        clearConnectionError: historyDone,
        // The WS history is capped at 50 with no cursor: a batch that came
        // back short means there is nothing older to load. Never flip an
        // already-confirmed false back to true (e.g. after paging to the
        // end, a reconnect replay of the last 50 would still look full).
        hasMoreHistory: historyDone
            ? state.hasMoreHistory && _historyCouldHaveMore(messages)
            : state.hasMoreHistory,
        messages: historyDone ? messages : [...messages, _systemMessage(event)],
      );

    case WsReadEvent():
      // Read receipt: upsert the reader's cursor, and (for my own messages
      // up to their cursor) attach the reader to seenBy — mirroring the
      // server's sender-only rule. The backend broadcasts `read` to the
      // whole room including the reader's own socket, so a reader's own
      // event must never attach them to their own messages (the sender is
      // never a "seen by" for their own bubbles).
      final cursors = Map<String, ReadCursor>.of(state.readCursors);
      final lastReadAt = event.lastReadAt;
      final isSelf = myUserId != null && event.userId == myUserId;
      if (!isSelf) {
        cursors[event.userId] = ReadCursor(
          username: event.username,
          lastReadAt: lastReadAt,
        );
      }
      var messages = state.messages;
      if (lastReadAt != null && myUserId != null && !isSelf) {
        messages = [
          for (final m in state.messages)
            if (m.author?.clerkId == myUserId &&
                m.createdAt != null &&
                !m.createdAt!.isAfter(lastReadAt) &&
                m.seenBy.every((s) => s.userId != event.userId))
              m.copyWith(
                seenBy: [
                  ...m.seenBy,
                  SeenByUser(
                    userId: event.userId,
                    username: event.username,
                    lastReadAt: event.lastReadAt,
                  ),
                ],
              )
            else
              m,
        ];
      }
      return state.copyWith(readCursors: cursors, messages: messages);

    case WsErrorEvent():
      return state.copyWith(lastError: event.text);

    // file-ack / file-progress / file-complete / unknown: handled by the
    // media task (20); nothing to do for the text view.
    default:
      return state;
  }
}

/// True when the messages in hand could still have older history behind
/// them: only a full-cap batch (or a longer, already-paginated list) leaves
/// that possibility. History system rows carry real ids, so only the
/// synthetic `sys-…` rows are excluded from the count.
bool _historyCouldHaveMore(List<ChatMessage> messages) {
  var count = 0;
  for (final m in messages) {
    final id = m.id;
    if (id != null && !id.startsWith('sys-')) {
      count++;
      if (count >= _wsHistoryCap) return true;
    }
  }
  return false;
}

ChatMessage _systemMessage(WsSystemEvent event) => ChatMessage(
  id: 'sys-${event.type}-${event.createdAt?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}',
  content: event.text,
  contentType: 'system',
  event: event.type == 'system' ? null : event.type,
  createdAt: event.createdAt,
);

/// Adds a message, replacing any existing message with the same id
/// (history + live broadcasts can overlap). Also replaces the optimistic
/// copy of a just-sent message: the server echo has the real [ChatMessage.id]
/// while the optimistic entry carries the same value in [ChatMessage.pendingId].
List<ChatMessage> _upsertMessage(
  List<ChatMessage> messages,
  ChatMessage message,
) {
  // The echo carries the optimistic `pendingId` round-tripped from the
  // sender; once stored, drop it so `status` reports `sent` (and other
  // participants never keep a stale "pending" bubble).
  final stored = message.pendingId == null
      ? message
      : message.copyWith(clearPendingId: true);

  var index = -1;
  if (message.id != null) {
    index = messages.indexWhere((m) => m.id == message.id);
  }
  if (index == -1 && message.pendingId != null) {
    index = messages.indexWhere((m) => m.pendingId == message.pendingId);
  }
  if (index == -1) return [...messages, stored];
  final next = [...messages];
  next[index] = stored;
  return next;
}

/// Stores the avatar URL from a message author so online users get their
/// real image: presence broadcasts only carry userId + username, messages
/// carry `profileImageUrl`. The entry is kept even while the user is
/// offline, and the presence handler merges it back in on the next
/// `online` broadcast.
Map<String, ChatUser> _rememberAvatar(
  Map<String, ChatUser> onlineUsers,
  ChatUser? author,
) {
  if (author == null || author.clerkId == null) return onlineUsers;
  if (author.profileImageUrl == null) return onlineUsers;
  final existing = onlineUsers[author.clerkId];
  if (existing?.profileImageUrl == author.profileImageUrl) return onlineUsers;
  final next = Map<String, ChatUser>.of(onlineUsers);
  next[author.clerkId!] = ChatUser(
    clerkId: existing?.clerkId ?? author.clerkId,
    username: existing?.username ?? author.username,
    profileImageUrl: author.profileImageUrl,
  );
  return next;
}

/// Merges a REST history page (oldest → newest, all older than what we
/// have) into the existing messages, deduplicating by id (the WS history
/// and REST can overlap after reconnect). Pure, so it's unit-testable.
List<ChatMessage> mergeMessages(
  List<ChatMessage> existing,
  List<ChatMessage> page,
) {
  if (page.isEmpty) return existing;
  final knownIds = {
    for (final m in existing)
      if (m.id != null) m.id!,
  };
  final fresh = [
    for (final m in page)
      if (m.id == null || !knownIds.contains(m.id)) m,
  ];
  if (fresh.isEmpty) return existing;
  // Drop optimistic entries that the REST page now covers (matched by
  // pendingId), instead of duplicating them.
  final covered = {for (final m in fresh) m.id};
  final merged = existing
      .where((m) => m.pendingId == null || !covered.contains(m.pendingId))
      .toList();
  return [...fresh, ...merged];
}
