import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/reconnect_policy.dart';
import '../core/ws_client.dart';
import '../models/message.dart';
import '../models/ws_event.dart';
import '../services/dictionary_crypto.dart';
import 'auth_providers.dart';
import 'chat_list_provider.dart';
import 'dictionary_provider.dart';
import 'repository_providers.dart';

// The pure state half ([ChatRoomState], [applyChatEvent], [mergeMessages],
// upload progress types) lives in chat_room_state.dart. Re-exported here so
// existing imports of this file keep working.
export 'chat_room_state.dart';
import 'chat_room_state.dart';

/// Builds the chat [WsClient] for a room. Defaults to connecting to the
/// backend via [AppConfig.chatWsUrl]; tests inject a factory pointing at a
/// local mock server. The controller wires [onEvent]/[onClose] itself.
typedef ChatWsClientFactory =
    WsClient<WsEvent> Function({
      required void Function(WsEvent event) onEvent,
      required void Function() onClose,
    });

/// Per-room chat WebSocket: connects on open, reconnects on drop, exposes
/// send/edit/delete/typing/file-upload. State is updated purely via
/// [applyChatEvent]; file uploads update [ChatRoomState.uploads] directly.
class ChatRoomController
    extends AutoDisposeFamilyNotifier<ChatRoomState, String> {
  ChatRoomController({
    this.clientFactory,
    this.fileStartAckTimeout = defaultFileStartAckTimeout,
  });

  /// Test hook: builds the chat [WsClient] instead of connecting to
  /// [AppConfig.chatWsUrl]. Null in production.
  final ChatWsClientFactory? clientFactory;

  /// Client-side cap for uploads (the server allows 10 MB).
  static const int maxUploadBytes = maxUploadBytesLimit;

  /// Chunk size for binary sends so the server's `file-progress` events
  /// reflect real progress.
  static const int _uploadChunkSize = 128 * 1024;

  /// How long `sendFile` waits for the server's `file-start` acknowledgment
  /// before giving up and reporting a failure.
  static const Duration defaultFileStartAckTimeout = Duration(seconds: 10);

  /// Overridable in tests to avoid a 10-second wait on the timeout path.
  final Duration fileStartAckTimeout;

  WsClient<WsEvent>? _client;
  Timer? _reconnectTimer;
  final Map<String, Timer> _typingTimers = {};
  DateTime? _lastTypingSentAt;
  Timer? _markReadTimer;
  static const Duration _markReadDebounce = Duration(milliseconds: 500);
  String? _lastAckedId;
  Timer? _ackReadTimer;
  bool _stopped = true;

  /// Exponential backoff for reconnects; reset on the `Welcome!` event.
  /// Public so the UI can read [ReconnectPolicy.attempts].
  final ReconnectPolicy reconnectPolicy = ReconnectPolicy();

  /// The upload currently being sent (the server holds one `pendingFile`
  /// per socket, so only one at a time).
  String? _activeUploadId;

  /// Completes once the server acknowledges (`file-ack`) or rejects
  /// (`error`) a `file-start`. `sendFile` awaits this before streaming any
  /// binary chunks so a rejected start never wastes the upload or triggers a
  /// spurious "Unexpected binary data" error.
  Completer<String?>? _fileStartAck;

  /// Auto-dismisses the transient [ChatRoomState.lastError] banner.
  Timer? _lastErrorTimer;

  String get chatId => arg;

  @override
  ChatRoomState build(String chatId) {
    _stopped = false;
    // Offline launch: seed from the cache, then let the socket's fresh
    // history (and the `Welcome!` event) replace it.
    final cached = ref.read(chatCacheProvider).readRoom(chatId);
    final initial = cached == null
        ? const ChatRoomState()
        : ChatRoomState(
            // Drop any cached "left the chat" rows (no longer posted).
            messages: [
              for (final m in cached.messages)
                if (m.event != 'leave') m,
            ],
            hasMoreHistory: cached.hasMore,
            historyCursor: cached.cursor,
            isLoading: true,
          );
    state = initial;
    _connect();
    ref.onDispose(() {
      _stopped = true;
      _reconnectTimer?.cancel();
      _lastErrorTimer?.cancel();
      for (final timer in _typingTimers.values) {
        timer.cancel();
      }
      _typingTimers.clear();
      _markReadTimer?.cancel();
      _ackReadTimer?.cancel();
      _client?.dispose();
      _client = null;
    });
    return initial;
  }

  /// Sets [next] as the state and persists the room to the offline cache
  /// (best-effort, fire-and-forget). All state mutations go through this.
  void set(ChatRoomState next) {
    state = next;
    try {
      ref
          .read(chatCacheProvider)
          .writeRoom(
            chatId,
            messages: next.messages,
            cursor: next.historyCursor,
            hasMore: next.hasMoreHistory,
          );
    } on StateError {
      // Provider read after dispose — nothing to persist.
    }
  }

  /// The current user's Clerk id (for sender-only read-receipt handling).
  String? get _myUserId => ref.read(currentUserProvider)?.clerkId;

  Future<void> _connect() async {
    if (_stopped) return;

    final factory = clientFactory;
    final WsClient<WsEvent> client;
    if (factory != null) {
      client = factory(onEvent: _handleEvent, onClose: _scheduleReconnect);
    } else {
      final snapshot = ref.read(clerkAuthProvider);
      final auth = snapshot?.auth;
      if (auth == null || !auth.isSignedIn) return;
      final token = (await auth.sessionToken()).jwt;
      client = WsClient<WsEvent>(
        url: AppConfig.chatWsUrl(chatId: chatId),
        protocols: [AppConfig.wsSubprotocol, token],
        parser: WsEvent.fromJson,
        onEvent: _handleEvent,
        onClose: _scheduleReconnect,
      );
    }

    await _client?.dispose();
    _client = client;
    await client.connect();
  }

  void _handleEvent(WsEvent event) {
    final myUserId = _myUserId;
    switch (event) {
      case WsTypingEvent():
        set(applyChatEvent(state, event, myUserId: myUserId));
        _scheduleTypingClear(event.userId);
        break;
      case WsDictionaryUpdateEvent():
        // A member saved the dictionary elsewhere — refresh locally so
        // send-replace and tap-to-reveal stay in sync.
        ref.read(dictionaryProvider(chatId).notifier).reload();
        set(applyChatEvent(state, event, myUserId: myUserId));
        break;
      case WsFileProgressEvent():
        _updateUploadProgress(event.progress);
        break;
      case WsFileAckEvent():
        // `file-start` accepted — release `sendFile` so it starts streaming.
        _completeFileStartAck(null);
        break;
      case WsFileCompleteEvent():
        _completeUpload();
        break;
      case WsErrorEvent():
        // A rejection while `sendFile` is awaiting the file-start ack is
        // handed back to it (so it can stop before streaming chunks);
        // otherwise it's a mid-upload failure — fail the active upload and
        // let the UI explain why.
        if (!_completeFileStartAck(event.text)) {
          _failActiveUpload(event.text);
        }
        set(applyChatEvent(state, event));
        _scheduleClearLastError();
        break;
      default:
        // message / edit / delete / presence / system / file-ack / unknown
        set(applyChatEvent(state, event, myUserId: myUserId));
    }
  }

  /// Completes the pending `file-start` acknowledgment. `null` means the
  /// server accepted the upload; any other value is the rejection reason.
  /// Returns true when there was a pending ack to complete.
  bool _completeFileStartAck(String? reason) {
    final ack = _fileStartAck;
    if (ack == null || ack.isCompleted) return false;
    _fileStartAck = null;
    ack.complete(reason);
    return true;
  }

  /// The `lastError` banner is transient: dismiss it shortly after it's
  /// shown so it doesn't linger forever (the connection banner is separate
  /// and persists until the socket reconnects).
  void _scheduleClearLastError() {
    _lastErrorTimer?.cancel();
    _lastErrorTimer = Timer(const Duration(seconds: 5), () {
      if (_stopped) return;
      if (state.lastError != null) {
        set(state.copyWith(clearError: true));
      }
    });
  }

  /// Viewport read-ack (read receipts): reports the newest message on
  /// screen and, debounced + deduped, sends `{type: "read", upToMessageId}`
  /// over the room socket. This replaces the old blanket chat-list
  /// `mark-read` — a badge clears because the server pushes `unread-update`
  /// back to the reader's chat-list sockets after each ack.
  void acknowledgeRead(String? messageId) {
    // A disposed (or never-started) controller must not schedule timers.
    if (_stopped) return;
    if (messageId == null || messageId.isEmpty) return;
    // Already sent this exact ack — a scroll re-reporting the same newest
    // visible message must not spam the server (the cursor is forward-only
    // server-side, so re-acking is also pointless).
    if (messageId == _lastAckedId) return;
    _ackReadTimer?.cancel();
    _ackReadTimer = Timer(_markReadDebounce, () {
      if (_stopped) return;
      final client = _client;
      if (client != null && client.isConnected) {
        client.sendJson({'type': 'read', 'upToMessageId': messageId});
        _lastAckedId = messageId;
      }
    });
  }

  void _updateUploadProgress(int progress) {
    final uploadId = _activeUploadId;
    if (uploadId == null) return;
    set(
      state.copyWith(
        uploads: {
          ...state.uploads,
          uploadId:
              (state.uploads[uploadId] ??
                      const UploadProgress(name: '', progress: 0))
                  .copyWith(progress: progress),
        },
      ),
    );
  }

  void _completeUpload() {
    final uploadId = _activeUploadId;
    if (uploadId == null) return;
    debugPrint('Upload complete: $uploadId');
    _activeUploadId = null;
    final next = Map<String, UploadProgress>.of(state.uploads)
      ..remove(uploadId);
    set(state.copyWith(uploads: next, clearUploadError: true));
  }

  /// Removes the in-flight upload row and records [reason] so the UI can
  /// explain *why* the upload failed instead of just dropping the progress
  /// bar silently. Also releases a `sendFile` that's still awaiting the
  /// file-start ack (e.g. the socket dropped mid-wait).
  void _failActiveUpload(String reason) {
    final uploadId = _activeUploadId;
    if (uploadId == null) return;
    _completeFileStartAck(reason);
    debugPrint('Upload failed ($uploadId): $reason');
    _activeUploadId = null;
    final next = Map<String, UploadProgress>.of(state.uploads)
      ..remove(uploadId);
    set(state.copyWith(uploads: next, uploadError: reason));
  }

  /// Clears the recorded upload failure once the UI has surfaced it (so a
  /// later identical failure still triggers the snackbar).
  void clearUploadError() {
    if (state.uploadError == null) return;
    set(state.copyWith(clearUploadError: true));
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    // A drop mid-upload orphans the pending file on the server — fail it so
    // the progress row doesn't hang forever and the user learns why.
    if (_activeUploadId != null) {
      _failActiveUpload('Upload failed: connection lost');
    }
    _reconnectTimer?.cancel();
    // Exponential backoff; `_connect` fetches a fresh Clerk JWT every time,
    // so the token is implicitly refreshed on each reconnect.
    final delay = reconnectPolicy.nextDelay();
    final lastError = _client?.lastError;
    // Surface the failure (error + redacted URL) in the reconnect banner;
    // a clean server close carries no error, so the detail is cleared.
    set(
      state.copyWith(
        reconnectAttempts: reconnectPolicy.attempts,
        connectionError: lastError == null
            ? null
            : '${lastError.message} (${lastError.url})',
        clearConnectionError: lastError == null,
      ),
    );
    _reconnectTimer = Timer(delay, _connect);
  }

  void _scheduleTypingClear(String userId) {
    _typingTimers[userId]?.cancel();
    _typingTimers[userId] = Timer(const Duration(seconds: 3), () {
      if (state.typingUserIds.contains(userId)) {
        state = state.copyWith(
          typingUserIds: {...state.typingUserIds}..remove(userId),
        );
      }
      _typingTimers.remove(userId);
    });
  }

  // ── Pagination ──────────────────────────────────────────────────────

  /// Fetches the next older page via `GET /chats/:id/messages?before=` and
  /// prepends it to the message list. The cursor is the oldest WS-history
  /// message id for the first page, then the server's `nextCursor`.
  Future<void> loadOlderMessages() async {
    if (state.isLoadingMore || !state.hasMoreHistory) return;
    set(state.copyWith(isLoadingMore: true, clearLoadMoreError: true));

    final cursor = state.historyCursor ?? _initialCursor();
    try {
      final page = await ref
          .read(messagesRepositoryProvider)
          .getMessages(chatId, before: cursor);
      set(
        state.copyWith(
          messages: mergeMessages(state.messages, page.messages),
          hasMoreHistory: page.more,
          historyCursor: page.nextCursor ?? state.historyCursor,
          isLoadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } on Exception catch (e) {
      set(
        state.copyWith(
          isLoadingMore: false,
          loadMoreError: 'Could not load older messages ($e)',
        ),
      );
    }
  }

  /// The oldest message we have becomes the `before` cursor (the server
  /// treats it as a message id — or an ISO timestamp — and pages older
  /// messages from there).
  String? _initialCursor() {
    if (state.messages.isEmpty) return null;
    // Only real message ids are valid cursors — synthetic live system rows
    // (id: 'sys-…') would be rejected by the server. Messages are stored
    // oldest-first, so the first real id is the oldest persisted message.
    for (final m in state.messages) {
      final id = m.id;
      if (id != null && !id.startsWith('sys-')) return id;
    }
    return null;
  }

  // ── Outbound ────────────────────────────────────────────────────────

  int _pendingCounter = 0;

  /// Sends a text message (optionally as a reply to [replyToId]) with an
  /// optimistic bubble. The server echo (real message id) replaces the
  /// optimistic entry via `pendingId`. If the socket is down the bubble is
  /// marked failed and can be retried with [retryMessage].
  void sendText(String content, {String? replyToId}) {
    // Code-word privacy layer: swap real words for codes in-flight, so only
    // opaque codes leave the device / reach the server.
    final entries = ref.read(dictionaryProvider(chatId)).entries;
    final text = DictionaryCrypto.replaceOutgoing(content.trim(), entries);
    if (text.isEmpty) return;

    final pendingId = 'pending-$chatId-${++_pendingCounter}';
    final optimistic = ChatMessage(
      id: pendingId,
      pendingId: pendingId,
      content: text,
      contentType: 'text',
      replyToId: replyToId,
      createdAt: DateTime.now(),
      author: ref.read(currentUserProvider),
      sendFailed: _client?.isConnected != true,
    );
    set(state.copyWith(messages: [...state.messages, optimistic]));

    if (optimistic.sendFailed) return;
    _client?.sendJson({
      'type': 'message',
      'content': text,
      'contentType': 'text',
      'pendingId': pendingId,
      'replyTo': ?replyToId,
    });
  }

  /// Retries a failed optimistic message: removes it and re-sends the text.
  void retryMessage(String id) {
    final failed = state.messages
        .where((m) => m.id == id || m.pendingId == id)
        .toList();
    if (failed.isEmpty) return;
    final message = failed.first;
    final replyToId = message.replyToId;
    set(
      state.copyWith(
        messages: [
          for (final m in state.messages)
            if (m.id != id && m.pendingId != id) m,
        ],
      ),
    );
    sendText(message.content, replyToId: replyToId);
  }

  void editMessage(String messageId, String newContent) {
    final entries = ref.read(dictionaryProvider(chatId)).entries;
    final coded = DictionaryCrypto.replaceOutgoing(newContent.trim(), entries);
    _client?.sendJson({
      'type': 'edit',
      'messageId': messageId,
      'newContent': coded,
    });
  }

  void deleteMessage(String messageId) {
    _client?.sendJson({'type': 'delete', 'messageId': messageId});
  }

  /// "Delete for me": hides the message from this user's own view. The
  /// bubble is removed optimistically, then confirmed via REST; on failure
  /// the message is restored at its original position and the method
  /// returns false so the UI can surface the error.
  Future<bool> deleteMessageForMe(String messageId) async {
    final index = state.messages.indexWhere(
      (m) => m.id == messageId || m.pendingId == messageId,
    );
    if (index == -1) return false;
    final original = state.messages[index];
    set(state.copyWith(messages: [...state.messages]..removeAt(index)));
    try {
      await ref.read(messagesRepositoryProvider).deleteForMe(chatId, messageId);
      return true;
    } on Exception {
      if (ref.exists(chatRoomProvider(chatId))) {
        final restored = [...state.messages]..insert(index, original);
        set(state.copyWith(messages: restored));
      }
      return false;
    }
  }

  /// Sends a typing ping, throttled to once every 3 seconds (the UI calls
  /// this on every keystroke).
  void sendTyping() {
    final now = DateTime.now();
    if (_lastTypingSentAt != null &&
        now.difference(_lastTypingSentAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastTypingSentAt = now;
    _client?.sendJson({'type': 'typing'});
  }

  /// Uploads a file via the WS protocol:
  ///   `file-start` (JSON) → `file-ack` → binary chunk(s) → `file-complete`.
  ///
  /// Returns null on success, or a human-readable reason when nothing was
  /// sent (socket closed, file empty/over [maxUploadBytes], another upload in
  /// flight, or the server rejecting the `file-start`). The chunks are only
  /// streamed after the server acknowledges, so a rejected start never sends
  /// stray binary data. The created file message arrives via the normal
  /// `message` broadcast.
  Future<String?> sendFile({
    required String name,
    required List<int> bytes,
    required String mime,
    String? caption,
    String? replyToId,
  }) async {
    final client = _client;
    if (client == null || !client.isConnected) {
      debugPrint('sendFile rejected: not connected ($name, ${bytes.length} B)');
      return UploadFailure.notConnected.message;
    }
    if (bytes.isEmpty) return UploadFailure.empty.message;
    if (bytes.length > maxUploadBytes) return UploadFailure.tooLarge.message;
    if (_activeUploadId != null) return UploadFailure.busy.message;

    final uploadId = 'upload-${DateTime.now().millisecondsSinceEpoch}';
    _activeUploadId = uploadId;
    debugPrint('sendFile started: $uploadId ($name, ${bytes.length} B, $mime)');
    set(
      state.copyWith(
        uploads: {
          ...state.uploads,
          uploadId: UploadProgress(name: name, progress: 0),
        },
      ),
    );

    client.sendJson({
      'type': 'file-start',
      'name': name,
      'size': bytes.length,
      'mime': mime,
      'caption': ?caption,
      'replyTo': ?replyToId,
    });

    // Wait for the server to accept the file-start (or reject it / drop the
    // connection) before streaming any chunks.
    final ack = _fileStartAck = Completer<String?>();
    final rejected = await ack.future.timeout(
      fileStartAckTimeout,
      onTimeout: () => 'Server did not acknowledge the upload',
    );
    if (rejected != null) {
      // The server refused the upload (or the ack never arrived) — drop the
      // progress row without a second notification; the caller surfaces the
      // reason returned here.
      debugPrint('sendFile rejected by server ($uploadId): $rejected');
      _activeUploadId = null;
      final next = Map<String, UploadProgress>.of(state.uploads)
        ..remove(uploadId);
      set(state.copyWith(uploads: next));
      return rejected;
    }

    // Send in chunks so the server's file-progress events reflect real
    // progress instead of jumping straight to 100%.
    var chunks = 0;
    for (var offset = 0; offset < bytes.length; offset += _uploadChunkSize) {
      final end = math.min(offset + _uploadChunkSize, bytes.length);
      client.sendBinary(bytes.sublist(offset, end));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      chunks++;
    }
    debugPrint('sendFile: sent $chunks chunk(s) for $uploadId');
    return null;
  }
}

final chatRoomProvider = NotifierProvider.autoDispose
    .family<ChatRoomController, ChatRoomState, String>(ChatRoomController.new);
