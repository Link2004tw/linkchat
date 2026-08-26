import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/chat_cache.dart';
import '../core/config.dart';
import '../core/reconnect_policy.dart';
import '../core/ws_client.dart';
import '../models/chat.dart';
import '../models/ws_event.dart';
import 'auth_providers.dart';
import 'dictionary_provider.dart';
import 'repository_providers.dart';

/// Connection status of the chat-list socket, for the UI banner:
/// [lastError] carries the failure detail (error + redacted URL) when the
/// last drop was a connection error rather than a clean close.
typedef ChatListConnection = ({bool isConnected, int attempts, WsFailure? lastError});

/// The offline cache. Overridden in `main()` with the opened Hive box;
/// defaults to an in-memory store (used by tests).
final chatCacheProvider = Provider<ChatCache>((ref) => ChatCache.memory);

/// Manages the `/ws/chat-list` socket: connects with a fresh Clerk JWT,
/// reconnects on drop, and fans events out to listeners.
///
/// A [ChangeNotifier] so UI can observe the connection state ([isConnected],
/// [reconnectPolicy], [lastError]) — the events stream alone can't signal
/// drops, since the broadcast controller stays open.
class ChatListSocket extends ChangeNotifier {
  ChatListSocket({required this.getToken});

  /// Returns the current Clerk JWT, or null when signed out.
  final Future<String?> Function() getToken;
  final StreamController<ChatListEvent> _events =
      StreamController.broadcast();
  WsClient<ChatListEvent>? _client;
  Timer? _reconnectTimer;
  String? _pendingMarkReadChatId;
  bool _stopped = true;

  /// Exponential backoff for reconnects; reset on the `connected` event.
  /// `_connect` fetches a fresh JWT every time, so the token is implicitly
  /// refreshed on each reconnect.
  final ReconnectPolicy reconnectPolicy = ReconnectPolicy();

  Stream<ChatListEvent> get events => _events.stream;

  /// The most recent connection failure (error + redacted URL), for
  /// surfacing why the chat list has gone stale. Cleared on the next
  /// successful connect.
  WsFailure? get lastError => _client?.lastError;

  /// True once the server has sent the `connected` handshake; false while
  /// connecting, after a drop, or when stopped.
  bool _connected = false;

  bool get isConnected => _connected;

  /// Connects (or reconnects) the socket. Idempotent-ish: safe to call
  /// again after [stop] or a drop.
  Future<void> start() async {
    _stopped = false;
    _reconnectTimer?.cancel();
    await _connect();
  }

  /// Closes the socket and cancels reconnects. The stream stays usable, so
  /// [start] can be called again later (e.g. after re-sign-in).
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _connected = false;
    await _client?.dispose();
    _client = null;
    notifyListeners();
  }

  Future<void> _connect() async {
    if (_stopped) return;
    final token = await getToken();
    if (token == null) return;

    await _client?.dispose();
    final client = WsClient<ChatListEvent>(
      url: AppConfig.chatListWsUrl(),
      protocols: [AppConfig.wsSubprotocol, token],
      parser: ChatListEvent.fromJson,
      onEvent: (event) {
        if (!_stopped) _events.add(event);
        // The server's `connected` event marks a successful handshake.
        if (event is ChatListConnectedEvent) {
          _connected = true;
          reconnectPolicy.reset();
          _flushPendingMarkRead();
          notifyListeners();
        }
      },
      onClose: _scheduleReconnect,
    );
    _client = client;
    await client.connect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();
    final delay = reconnectPolicy.nextDelay();
    // Failures are logged with the target URL (token redacted) so they're
    // traceable, and the notifier tells the UI to surface the banner.
    final lastError = _client?.lastError;
    if (lastError != null) {
      debugPrint(
        'chat-list WS failed: ${lastError.message} — ${lastError.url} '
        '(retrying in ${delay.inMilliseconds}ms)',
      );
    }
    _connected = false;
    notifyListeners();
    _reconnectTimer = Timer(delay, _connect);
  }

  /// Sends `mark-read` for [chatId] (the server then pushes
  /// `unread-update` with 0). When the socket isn't connected (e.g. mid
  /// reconnect) the request is queued and flushed on the next `connected`
  /// event, so a drop never silently loses a mark-read.
  void sendMarkRead(String chatId) {
    if (_client?.isConnected != true) {
      _pendingMarkReadChatId = chatId;
      return;
    }
    _client!.sendJson({'type': 'mark-read', 'chatId': chatId});
  }

  /// True when a mark-read is queued awaiting the next connection.
  bool get hasPendingMarkRead => _pendingMarkReadChatId != null;

  void _flushPendingMarkRead() {
    final chatId = _pendingMarkReadChatId;
    _pendingMarkReadChatId = null;
    if (chatId != null) sendMarkRead(chatId);
  }

  @override
  Future<void> dispose() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    await _client?.dispose();
    _client = null;
    await _events.close();
    super.dispose();
  }
}

/// The live socket — lives for the app session, started/stopped with auth.
final chatListSocketProvider = Provider<ChatListSocket>((ref) {
  final socket = ChatListSocket(
    getToken: () async {
      final snapshot = ref.read(clerkAuthProvider);
      final auth = snapshot?.auth;
      if (auth == null || !auth.isSignedIn) return null;
      return (await auth.sessionToken()).jwt;
    },
  );
  ref.onDispose(socket.dispose);
  return socket;
});

/// Live events from the chat-list socket. Started when signed in, stopped
/// when signed out (AuthGate invalidates this on sign-out).
final chatListEventsProvider = StreamProvider<ChatListEvent>((ref) {
  final snapshot = ref.watch(clerkAuthProvider);
  final auth = snapshot?.auth;
  final socket = ref.watch(chatListSocketProvider);
  if (auth == null || !auth.isSignedIn) {
    socket.stop();
    return const Stream.empty();
  }
  socket.start();
  return socket.events;
});

/// Connection status of the chat-list socket for the UI (the chat list has
/// no per-event way to observe drops — the socket notifies instead).
final chatListConnectionProvider =
    NotifierProvider<ChatListConnectionController, ChatListConnection>(
  ChatListConnectionController.new,
);

class ChatListConnectionController extends Notifier<ChatListConnection> {
  ChatListSocket? _socket;

  @override
  ChatListConnection build() {
    final socket = ref.watch(chatListSocketProvider);
    _socket = socket;
    socket.addListener(_onSocketChanged);
    ref.onDispose(() => socket.removeListener(_onSocketChanged));
    return _snapshot(socket);
  }

  void _onSocketChanged() {
    final socket = _socket;
    if (socket == null) return;
    state = _snapshot(socket);
  }

  ChatListConnection _snapshot(ChatListSocket socket) => (
        isConnected: socket.isConnected,
        attempts: socket.reconnectPolicy.attempts,
        lastError: socket.lastError,
      );
}

/// Sends `mark-read` over the socket — call when a room is opened.
final markChatAsReadProvider = Provider<void Function(String chatId)>((ref) {
  return (chatId) => ref.read(chatListSocketProvider).sendMarkRead(chatId);
});

/// Applies a chat-list event to the current list. Pure so it can be unit
/// tested without Riverpod.
///
/// Returns the updated list; when an event references a chat not in the
/// list, [onMissingChat] is invoked so the caller can refetch from REST.
List<ChatSummary> reduceChatList(
  List<ChatSummary> chats,
  ChatListEvent event, {
  void Function()? onMissingChat,
}) {
  switch (event) {
    case ChatListNewMessageEvent():
      final updated = _updateChat(
        chats,
        event.chatId,
        (c) => c.copyWith(
          lastMessage: ChatLastMessage(
            content: event.lastMessage?.content ?? '',
            sentAt: event.lastMessage?.createdAt,
            senderName: event.lastMessage?.author?.username,
            contentType: event.lastMessage?.contentType,
            mediaUrl: event.lastMessage?.mediaUrl,
          ),
          unreadCount: event.unreadCount,
          mentionedCount: event.mentionedCount,
        ),
      );
      if (updated == null) {
        onMissingChat?.call();
        return chats;
      }
      return _sortByRecency(updated);

    case ChatListUnreadUpdateEvent():
      return _updateChat(
            chats,
            event.chatId,
            (c) => c.copyWith(
              unreadCount: event.unreadCount,
              mentionedCount: event.mentionedCount,
            ),
          ) ??
          chats;    case ChatListRoomUpdateEvent():
      final updates = event.updates;
      final updated = _updateChat(
        chats,
        event.chatId,
        (c) => c.copyWith(
          name: updates['name'] is String ? updates['name'] as String : null,
          access: updates['access'] is String
              ? updates['access'] as String
              : null,
          pictureUrl: updates['pictureUrl'] is String
              ? updates['pictureUrl'] as String
              : null,
          mutedByUser: updates['mutedByUser'] is bool
              ? updates['mutedByUser'] as bool
              : null,
        ),
      );
      if (updated == null) {
        // Room change for a chat we haven't loaded yet (e.g. a rename that
        // raced the initial fetch) — pull the list fresh instead of
        // dropping the update.
        onMissingChat?.call();
        return chats;
      }
      return updated;

    case ChatListMembershipEvent():
      if (event.type == 'kicked' || event.type == 'leave-chat') {
        return chats.where((c) => c.id != event.chatId).toList();
      }
      if (event.type == 'invited') {
        // A chat we don't have yet was added — refresh from REST.
        onMissingChat?.call();
        return chats;
      }
      return chats;

    // connected / join-request / join-request-updated / unknown: nothing to
    // do for the chat list.
    default:
      return chats;
  }
}

List<ChatSummary>? _updateChat(
  List<ChatSummary> chats,
  String chatId,
  ChatSummary Function(ChatSummary) update,
) {
  var updated = false;
  final result = chats.map((c) {
    if (c.id == chatId) {
      updated = true;
      return update(c);
    }
    return c;
  }).toList();
  return updated ? result : null;
}

List<ChatSummary> _sortByRecency(List<ChatSummary> chats) {
  final sorted = [...chats];
  sorted.sort((a, b) {
    final at = a.lastMessage?.sentAt ?? a.updatedAt;
    final bt = b.lastMessage?.sentAt ?? b.updatedAt;
    return (bt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(at ?? DateTime.fromMillisecondsSinceEpoch(0));
  });
  return sorted;
}

/// The chat list: cached copy shown instantly on launch, then refreshed
/// from REST (`GET /chats/all` — which also creates the local backend user
/// on first call) and kept live by the chat-list socket. Every update is
/// written back to the cache.
///
/// A plain `Notifier<AsyncValue<...>>` rather than an `AsyncNotifier`:
/// `build()` returns the cached list synchronously (instant offline launch)
/// and kicks off a background REST refresh; an `AsyncNotifier` would emit
/// the stale cache *after* the fresh fetch and win the race.
class ChatListController extends AutoDisposeNotifier<AsyncValue<List<ChatSummary>>> {
  @override
  AsyncValue<List<ChatSummary>> build() {
    final cache = ref.watch(chatCacheProvider);
    final cached = cache.readChatList();

    ref.listen<AsyncValue<ChatListEvent>>(chatListEventsProvider, (prev, next) {
      next.whenData(_apply);
    });

    // Invalidate dictionary providers when another member saves changes,
    // so the dict is fresh when the user opens the room.
    ref.listen<AsyncValue<ChatListEvent>>(chatListEventsProvider, (prev, next) {
      next.whenData((event) {
        if (event is ChatListDictionaryUpdateEvent) {
          ref.invalidate(dictionaryProvider(event.chatId));
        }
      });
    });

    // Offline launch: show the cached list right away and refresh in the
    // background (a failed refresh keeps the cached list on screen). With
    // no cache, show a spinner and fetch in the background too.
    Future<void>.microtask(_fetch);
    if (cached != null && cached.isNotEmpty) return AsyncData(cached);
    return const AsyncLoading();
  }

  /// Background fetch that resolves the list and persists it. Guards with
  /// `ref.exists` so a fetch still in flight after the provider (or the
  /// whole container) was disposed doesn't touch dead state.
  Future<void> _fetch() async {
    try {
      final chats = await ref.read(chatsRepositoryProvider).getAll();
      if (!ref.exists(chatListProvider)) return;
      state = AsyncData(chats);
      _persist();
    } on Exception catch (e, st) {
      if (ref.exists(chatListProvider)) state = AsyncError(e, st);
    }
  }

  void _apply(ChatListEvent event) {
    state = state.whenData(
      (chats) => reduceChatList(chats, event, onMissingChat: _refreshSilently),
    );
    _persist();
  }

  /// Refetches from REST without flashing a loading state (used when an
  /// event references a chat we don't have yet, e.g. after an invite).
  /// Failures keep the current list on screen.
  Future<void> _refreshSilently() async {
    try {
      final chats = await ref.read(chatsRepositoryProvider).getAll();
      state = AsyncData(chats);
      _persist();
    } on Exception {
      // Keep the current list (and the cache); errors surface on refresh.
    }
  }

  /// Pull-to-refresh: refetches from REST; throws on failure so the caller
  /// can show an error.
  Future<void> refresh() async {
    final chats = await ref.read(chatsRepositoryProvider).getAll();
    state = AsyncData(chats);
    _persist();
  }

  /// Optimistically flips the self-mute flag for one chat (chat-list
  /// long-press menu). The server's `room-update {mutedByUser}` echo
  /// confirms; a REST refresh overwrites it if they ever diverge.
  void setSelfMuted(String chatId, bool muted) {
    final updated = _updateChat(
      state.valueOrNull ?? const [],
      chatId,
      (c) => c.copyWith(mutedByUser: muted),
    );
    if (updated == null) return;
    state = AsyncData(updated);
    _persist();
  }

  /// Writes the current list to the offline cache (best-effort).
  void _persist() {
    final chats = state.valueOrNull;
    if (chats == null) return;
    try {
      // Fire-and-forget: cache writes must never block the UI, and must
      // not throw if the container was disposed mid-flight.
      ref.read(chatCacheProvider).writeChatList(chats);
    } on StateError {
      // Provider read after dispose — nothing to persist.
    }
  }
}

final chatListProvider = NotifierProvider.autoDispose<
    ChatListController, AsyncValue<List<ChatSummary>>>(ChatListController.new);
