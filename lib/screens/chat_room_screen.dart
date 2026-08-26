import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../models/ws_event.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_list_provider.dart';
import '../providers/chat_room_provider.dart';
import '../providers/dictionary_provider.dart';
import '../providers/friends_providers.dart';
import '../services/dictionary_crypto.dart';
import '../providers/repository_providers.dart';
import '../utils/media_picker.dart';
import '../utils/save_image.dart';
import '../utils/snack.dart';
import '../widgets/chat/chat_input_bar.dart';
import '../widgets/chat/dictionary_unlock_sheet.dart';
import '../widgets/chat/message_list.dart';
import '../widgets/chat/message_search_sheet.dart';
import '../widgets/chat/typing_banner.dart';
import '../widgets/chat/upload_progress_bar.dart';
import '../widgets/status_banner.dart';
import 'dictionary_screen.dart';
import 'forward_to_screen.dart';
import 'room_details_screen.dart';

// Re-export the chat widgets so existing callers (tests and screens) that
// imported them from this file keep working.
export '../widgets/chat/chat_input_bar.dart';
export '../widgets/chat/message_bubble.dart';
export '../widgets/chat/message_list.dart';
export '../widgets/chat/message_search_sheet.dart';
export '../widgets/chat/typing_banner.dart';
export '../widgets/chat/upload_progress_bar.dart';

/// The chat room: live messages from the `/ws/chat` provider, presence in
/// the header, typing indicator, media uploads and a message input.
class ChatRoomScreen extends ConsumerStatefulWidget {
  const ChatRoomScreen({super.key, required this.chat});

  final ChatSummary chat;

  @override
  ConsumerState<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends ConsumerState<ChatRoomScreen> {
  /// Local copy of the room name so a rename from RoomDetailsScreen (or the
  /// live `room-update` event) can update the AppBar without reopening the room.
  late String _displayName = widget.chat.displayName;

  /// Live access policy, kept in sync via the chat-list `room-update` event
  /// (access changes made in RoomDetails — by me or another admin — appear
  /// without reopening the room).
  late String _access = widget.chat.access;

  /// Live can-send policy (`everyone` | `admins`); null until a `room-update`
  /// event reports it.
  String? _canSendMessages;

  /// Set to a message id when a search result is picked; [MessageList]
  /// listens and scrolls to + highlights that message.
  final ValueNotifier<String?> _scrollTarget = ValueNotifier<String?>(null);

  /// Room members for the `@` mention picker (from `GET /chats/:id/info`).
  /// Loaded lazily on the first `@` keystroke so opening a room never pays
  /// for a network call (or a pending-timeout timer in widget tests).
  List<RoomParticipant> _participants = const [];

  /// Room info (send policy, my role, members) from `GET /chats/:id/info`,
  /// fetched once on open for group rooms. Null until loaded (or for direct
  /// chats). Drives the read-only input state and the `@`-mention picker.
  RoomInfo? _info;

  /// Edit mode state: non-null when the user is editing a message.
  String? _editingMessageId;
  String? _editingText;

  /// Set after [_healStaleDmLock] fires once, so a server that still reports
  /// the DM as locked (race between the friends refresh and the policy
  /// reset) can't trigger an endless clear-and-refetch loop.
  bool _staleLockHealed = false;

  /// Whether the current user has self-muted this chat.
  bool get _isMutedByUser {
    final me = ref.read(currentUserProvider)?.clerkId;
    if (me == null || _info == null) return false;
    final myParticipant = _info!.participants.where((p) => p.clerkId == me);
    return myParticipant.any((p) => p.mutedByUser);
  }

  /// Fetches the room's members + send policy once; also called by the input
  /// bar the first time the user types `@`. Failures just leave the picker
  /// empty (the input stays enabled; the backend still enforces the policy
  /// server-side).
  Future<List<RoomParticipant>> _loadParticipants() async {
    if (_participants.isNotEmpty) return _participants;
    final known = _info;
    if (known != null) {
      _participants = known.participants;
      return _participants;
    }
    try {
      final info =
          await ref.read(chatsRepositoryProvider).getInfo(widget.chat.id);
      if (mounted) {
        setState(() {
          _info = info;
          _participants = info.participants;
        });
      }
      return info.participants;
    } catch (_) {
      return const [];
    }
  }

  /// Whether the current user may send, given the live policy (from the WS
  /// `room-update` event, most recent) and the policy/role from [RoomInfo].
  /// Unknown policy defaults to open ("everyone").
  static bool _canSend(String? livePolicy, String? infoPolicy, bool? isAdmin) {
    final policy = livePolicy ?? infoPolicy ?? 'everyone';
    return policy != 'admins' || isAdmin == true;
  }

  /// Locked non-friend DM: resolves the "Add as friend" CTA for the input
  /// bar. Returns null when the partner is a friend, already requested, or
  /// the friends data hasn't loaded (the read-only hint still shows).
  ({String label, Future<void> Function() onCta})? _lockedDmCta(bool canSend) {
    if (canSend || !widget.chat.isDm) return null;
    final otherClerkId = widget.chat.otherUser?.clerkId;
    if (otherClerkId == null || otherClerkId.isEmpty) return null;
    final friends = ref.watch(friendsProvider).valueOrNull;
    if (friends == null) return null;
    final isFriend = friends.any((f) => f.clerkId == otherClerkId);
    if (isFriend) return null;
    final requests = ref.watch(friendRequestsProvider).valueOrNull;
    final alreadyRequested =
        requests?.outgoing.any((r) => r.to.clerkId == otherClerkId) ?? false;
    if (alreadyRequested) return null;
    return (label: 'Add as friend', onCta: () => _sendFriendRequest(otherClerkId));
  }

  /// Sends a friend request to the DM partner from the locked-input CTA.
  /// Once accepted, the backend reopens the DM (`room-update`) and the input
  /// unlocks via the existing listener.
  Future<void> _sendFriendRequest(String clerkId) async {
    try {
      await ref.read(friendsRepositoryProvider).sendRequest(clerkId);
      ref.invalidate(friendsProvider);
      ref.invalidate(friendRequestsProvider);
      if (mounted) showSnack(context, 'Friend request sent');
    } catch (_) {
      if (mounted) showSnack(context, 'Could not send friend request');
    }
  }

  Future<void> _toggleSelfMute() async {
    if (_info == null) return;
    final repo = ref.read(chatsRepositoryProvider);
    try {
      if (_isMutedByUser) {
        await repo.unmuteSelf(widget.chat.id);
      } else {
        await repo.muteSelf(widget.chat.id);
      }
      // Re-fetch info to get the updated mutedByUser state.
      final info = await repo.getInfo(widget.chat.id);
      if (mounted) {
        setState(() {
          _info = info;
          _participants = info.participants;
        });
      }
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Toggle mute failed: $e');
    }
  }

  /// Self-healing for a missed unlock event: when the WS `room-update` that
  /// reopens a re-friended DM is lost (backgrounded socket, restart race),
  /// this room would stay locked even though the pair are friends again.
  /// "Partner is in my friends list while the policy says locked" means the
  /// reopen event went missing — clear the stale state once and refetch the
  /// room info (which now reports `everyone` server-side).
  void _healStaleDmLock() {
    if (!widget.chat.isDm) return;
    final otherClerkId = widget.chat.otherUser?.clerkId;
    if (otherClerkId == null || otherClerkId.isEmpty) return;
    final locked = (_canSendMessages ?? _info?.canSendMessages) == 'admins';
    // Only relevant (and only subscribed) while the room is actually
    // locked — an unlocked DM never needs healing.
    if (!locked || _staleLockHealed) return;
    final friends = ref.watch(friendsProvider).valueOrNull;
    if (friends == null) return;
    final isFriend = friends.any((f) => f.clerkId == otherClerkId);
    if (!isFriend) return;
    _staleLockHealed = true;
    debugPrint(
      'chat_room: DM partner is a friend but the room is still locked — refreshing',
    );
    // Plain field mutation (not setState) — we're inside build; the async
    // info refetch below applies its results via setState when done.
    _canSendMessages = null;
    _info = null;
    _participants = const [];
    if (ref.read(currentUserProvider) != null) {
      _loadParticipants();
    }
  }

  @override
  void dispose() {
    _scrollTarget.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = ref.watch(chatRoomProvider(widget.chat.id));
    final me = ref.watch(currentUserProvider);
    final controller = ref.read(chatRoomProvider(widget.chat.id).notifier);
    // Keep the per-chat dictionary alive + loaded while the room is open
    // so send-replace and tap-to-reveal have the latest code words.
    final dict = ref.watch(dictionaryProvider(widget.chat.id));

    // Seed the send policy + my role once on open so admins-only rooms lock
    // the input for non-admins right away (the backend also enforces this).
    // DMs are included: a DM locked read-only by a friend removal must render
    // the locked input on a fresh open too. Skipped when not signed in
    // (widget tests).
    if (_info == null && me != null) {
      _loadParticipants();
    }

    // Defense-in-depth unlock: if the partner is a friend again but the
    // room still thinks it's locked, the reopen `room-update` was missed —
    // drop the stale state and refetch.
    _healStaleDmLock();

    // The backend broadcasts room-update (name / access / canSendMessages)
    // to every participant's chat-list socket — listen so the AppBar stays
    // in sync without reopening the room.
    ref.listen<AsyncValue<ChatListEvent>>(chatListEventsProvider, (prev, next) {
      final event = next.valueOrNull;
      if (event is ChatListRoomUpdateEvent &&
          event.chatId == widget.chat.id) {
        final updates = event.updates;
        final name = updates['name'];
        final access = updates['access'];
        final canSend = updates['canSendMessages'];
        setState(() {
          if (name is String && name.isNotEmpty) _displayName = name;
          if (access is String) _access = access;
          if (canSend is String) _canSendMessages = canSend;
        });
      }
    });

    // Surface why an upload failed (server rejection, lost connection) in a
    // snackbar instead of silently dropping the progress bar, then clear the
    // flag so a later identical failure still notifies.
    ref.listen<String?>(
      chatRoomProvider(widget.chat.id).select((s) => s.uploadError),
      (prev, next) {
        if (next == null || next == prev) return;
        ref.read(chatRoomProvider(widget.chat.id).notifier).clearUploadError();
        showSnack(context, next);
      },
    );

    // "Add as friend" CTA for a DM the backend locked read-only after a
    // friend removal (null when unlocked or not applicable).
    final dmCta = _lockedDmCta(_canSend(
      _canSendMessages,
      _info?.canSendMessages,
      _info?.isAdmin,
    ));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_displayName, overflow: TextOverflow.ellipsis),
            Text(
              _subtitle(room),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isMutedByUser ? Icons.notifications_off : Icons.notifications_active,
              color: _isMutedByUser ? Colors.grey : null,
            ),
            tooltip: _isMutedByUser ? 'Unmute notifications' : 'Mute notifications',
            onPressed: _info == null ? null : _toggleSelfMute,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search messages',
            onPressed: () => _openSearch(context),
          ),
          IconButton(
            icon: const Icon(Icons.book_outlined),
            tooltip: 'Code words',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DictionaryScreen(chat: widget.chat),
              ),
            ),
          ),
          // Room settings — hidden for DMs, mirroring the web app (a direct
          // chat has no settings to change).
          if (!widget.chat.isDm)
            IconButton(
              // A gear — same affordance as the web app's room "Details"
              // button. `group_outlined` rendered like a people icon and was
              // easy to miss, so room settings now gets a proper gear.
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Room settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RoomDetailsScreen(
                    chat: widget.chat,
                    onRenamed: (name) {
                      if (mounted) setState(() => _displayName = name);
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (room.lastError != null) StatusBanner(text: room.lastError!),
          if (!room.isConnected && !room.isLoading)
            StatusBanner(
              // Include the specific failure (error + redacted URL) when
              // the drop was a connection error rather than a clean close.
              text: room.connectionError == null
                  ? 'Connection lost — reconnecting…'
                  : 'Connection lost — reconnecting…\n${room.connectionError}',
            ),
          Expanded(
            child: room.isLoading && room.messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : room.messages.isEmpty
                    ? const EmptyRoom()
                    : MessageList(
                        state: room,
                        me: me,
                        dictEntries: dict.entries,
                        onLoadOlder: controller.loadOlderMessages,
                        onRetryMessage: controller.retryMessage,
                        onEdit: _startEdit,
                        onDeleteForMe: _deleteForMe,
                        onDeleteForEveryone: controller.deleteMessage,
                        onSaveImage: _saveImage,
                        onForward: _forwardMessage,
                        isDm: widget.chat.isDm,
                        scrollTarget: _scrollTarget,
                        onNewestVisible: controller.acknowledgeRead,
                      ),
          ),
          TypingBanner(
            typingUserIds: {
              for (final id in room.typingUserIds)
                if (id != me?.clerkId) id,
            },
            onlineUsers: room.onlineUsers,
          ),
          UploadProgressBar(uploads: room.uploads),
          ChatInputBar(
            onSend: controller.sendText,
            onTyping: controller.sendTyping,
            onAttach: () => _pickMedia(context, ref, controller),
            onVoiceSend: (bytes, name, mime) =>
                _sendVoice(controller, bytes, name, mime),
            onEdit: _submitEdit,
            editingMessageId: _editingMessageId,
            editingInitialText: _editingText,
            onCancelEdit: _cancelEdit,
            participants: _participants,
            myUserId: me?.clerkId,
            loadParticipants: _loadParticipants,
            canSend: _isMutedByUser
                ? false
                : _canSend(
                    _canSendMessages,
                    _info?.canSendMessages,
                    _info?.isAdmin,
                  ),
            lockedHint: _isMutedByUser
                ? "You've muted this chat"
                : widget.chat.isDm
                    ? "The user is no longer your friend you can't text them anymore"
                    : null,
            lockedCtaLabel: dmCta?.label,
            onLockedCta: dmCta?.onCta,
          ),
        ],
      ),
    );
  }

  /// Photo/File picker → size check → WS upload.
  Future<void> _pickMedia(
    BuildContext context,
    WidgetRef ref,
    ChatRoomController controller,
  ) async {
    debugPrint('_pickMedia: showing source sheet');
    final source = await showModalBottomSheet<MediaSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Photo'),
              onTap: () => Navigator.of(sheetContext).pop(MediaSource.photo),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.of(sheetContext).pop(MediaSource.file),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;

    final PickedMedia? picked;
    try {
      picked = source == MediaSource.photo ? await pickImage() : await pickFile();
    } on Exception catch (e) {
      // A platform picker failure must never look like "nothing happened" —
      // surface it instead of silently dropping the pick.
      debugPrint('_pickMedia: picker threw: $e');
      if (context.mounted) {
        showSnack(context, 'Could not pick file — $e');
      }
      return;
    }
    if (picked == null || !context.mounted) return;
    debugPrint('_pickMedia: picked ${picked.name} (${picked.bytes.length} B, '
        '${picked.mime})');

    if (picked.bytes.length > ChatRoomController.maxUploadBytes) {
      showSnack(context, 'File too large (max 6 MB)');
      return;
    }
    debugPrint('_pickMedia: calling sendFile');
    final error = await controller.sendFile(
      name: picked.name,
      bytes: picked.bytes,
      mime: picked.mime,
    );
    if (error != null && context.mounted) {
      showSnack(context, 'Could not send file — $error');
    }
  }

  /// Uploads a recorded voice note via the same WS file-upload path as
  /// photos/files (the backend maps audio/* to the "audio" content type).
  Future<void> _sendVoice(
    ChatRoomController controller,
    Uint8List bytes,
    String name,
    String mime,
  ) async {
    final error = await controller.sendFile(
      name: name,
      bytes: bytes,
      mime: mime,
    );
    if (error != null && mounted) {
      showSnack(context, 'Could not send voice note — $error');
    }
  }

  /// "Delete for me": optimistic removal with restore-on-failure handled by
  /// the controller; a failure surfaces a snackbar here.
  Future<void> _deleteForMe(String messageId) async {
    final controller = ref.read(chatRoomProvider(widget.chat.id).notifier);
    final ok = await controller.deleteMessageForMe(messageId);
    if (!ok && mounted) {
      showSnack(context, 'Could not delete message');
    }
  }

  /// "Save image": download and import into the device gallery.
  Future<void> _saveImage(String url) async {
    final error = await saveImageToGallery(url);
    if (!mounted) return;
    showSnack(context, error ?? 'Image saved to gallery');
  }

  /// "Forward": pick a target chat (current room excluded), then copy the
  /// message there via the forward endpoint. The target chat's list updates
  /// on its own when the broadcast lands.
  Future<void> _forwardMessage(String messageId) async {
    final messenger = ScaffoldMessenger.of(context);
    final target = await Navigator.of(context).push<ChatSummary>(
      MaterialPageRoute(
        builder: (_) => ForwardToScreen(currentChatId: widget.chat.id),
      ),
    );
    if (target == null || !mounted) return;
    try {
      await ref.read(messagesRepositoryProvider).forward(
            sourceChatId: widget.chat.id,
            messageId: messageId,
            targetChatId: target.id,
          );
      showSnackVia(messenger, 'Forwarded to ${target.displayName}');
    } on Exception catch (e) {
      showSnackVia(messenger, 'Could not forward: $e');
    }
  }

  /// "Edit": enters edit mode by recording the message id and its current
  /// text so the input bar can pre-fill and send an edit on submit.
  void _startEdit(String messageId) {
    final messages = ref.read(chatRoomProvider(widget.chat.id)).messages;
    final msg = messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => const ChatMessage(id: '', content: ''),
    );
    if (msg.id == null || msg.id!.isEmpty) return;
    // Expand dictionary codes so the user sees the real text while editing.
    final dictState = ref.read(dictionaryProvider(widget.chat.id));
    final dictEntries = dictState.entries;
    final displayText = dictEntries.isEmpty
        ? msg.content
        : DictionaryCrypto.expandIncoming(msg.content, dictEntries);
    setState(() {
      _editingMessageId = messageId;
      _editingText = displayText;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingMessageId = null;
      _editingText = null;
    });
  }

  void _submitEdit(String messageId, String newText) {
    final controller = ref.read(chatRoomProvider(widget.chat.id).notifier);
    controller.editMessage(messageId, newText);
  }

  /// Opens the in-room message search (mirrors the web app's MessageSearch
  /// panel). Picking a result closes the sheet and jumps to that message.
  Future<void> _openSearch(BuildContext context) async {
    final messages =
        ref.read(chatRoomProvider(widget.chat.id)).messages;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => MessageSearchSheet(messages: messages),
    );
    if (picked == null || !mounted) return;
    // Null-first so re-picking the same message still fires the listener.
    _scrollTarget.value = null;
    _scrollTarget.value = picked;
  }

  /// AppBar subtitle: connection state, then (for groups) the live access
  /// policy and an "admins only" note when sending is restricted.
  ///
  /// The retry notice only appears after a genuine drop ([reconnectAttempts]
  /// is > 0 or the last connect errored) — the initial connect stays quiet
  /// so entering a room never flashes "reconnecting…".
  String _subtitle(ChatRoomState room) {
    final parts = <String>[];
    if (room.isConnected) {
      parts.add('${room.onlineUsers.length} online');
    } else if (room.reconnectAttempts > 0 || room.connectionError != null) {
      parts.add('reconnecting… (try ${room.reconnectAttempts + 1})');
    } else {
      parts.add('connecting…');
    }
    if (!widget.chat.isDm) {
      parts.add(_access);
      if (_canSendMessages == 'admins') parts.add('admins only');
    }
    return parts.join(' · ');
  }
}
