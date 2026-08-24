import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/dictionary.dart';
import '../../models/user.dart';
import '../../providers/chat_room_provider.dart';
import 'message_bubble.dart';

class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.state,
    required this.me,
    this.dictEntries = const [],
    this.onLoadOlder,
    this.onRetryMessage,
    this.onEdit,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.onSaveImage,
    this.onForward,
    this.isDm = false,
    this.scrollTarget,
    this.onNewestVisible,
  });

  final ChatRoomState state;
  final ChatUser? me;

  /// Code→meaning entries for tap-to-reveal (empty in non-dict chats).
  final List<DictEntry> dictEntries;

  /// Fetches the previous page of history; hidden when null or when the
  /// server reported no more history.
  final Future<void> Function()? onLoadOlder;

  /// Reports the id of the newest message currently on screen (read
  /// receipts): fired on layout, scroll, and when messages change. The
  /// provider debounces and sends the `read` ack.
  final void Function(String? messageId)? onNewestVisible;

  /// Retries a failed optimistic message (called on bubble tap).
  final void Function(String messageId)? onRetryMessage;

  /// Whether this is a direct (1:1) chat — used for simplified seen-by labels.
  final bool isDm;

  /// Long-press bubble actions.
  final void Function(String messageId)? onEdit;
  final void Function(String messageId)? onDeleteForMe;
  final void Function(String messageId)? onDeleteForEveryone;
  final void Function(String url)? onSaveImage;
  final void Function(String messageId)? onForward;

  /// Set to a message id to scroll to + highlight it.
  final ValueNotifier<String?>? scrollTarget;

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final ScrollController _scroll = ScrollController();

  /// Per-message keys so a search result can be scrolled to precisely.
  final Map<String, GlobalKey> _messageKeys = {};

  /// Message ids currently highlighted (fresh search results, cleared
  /// after ~2s).
  Set<String> _highlighted = const {};

  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    widget.scrollTarget?.addListener(_onScrollTarget);
    _scroll.addListener(_reportNewestVisible);
  }

  @override
  void dispose() {
    widget.scrollTarget?.removeListener(_onScrollTarget);
    _scroll.removeListener(_reportNewestVisible);
    _scroll.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _onScrollTarget() {
    final id = widget.scrollTarget?.value;
    if (id == null || !mounted) return;
    final messages = widget.state.messages;
    final index = messages.indexWhere((m) => m.id == id || m.pendingId == id);
    if (index == -1) return;

    setState(() => _highlighted = {id});
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlighted = const {});
    });

    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final maxExtent = position.maxScrollExtent;
    // Reversed list: chronological index 0 renders at the bottom (offset 0),
    // so the target sits at `maxExtent * (length - 1 - index) / length`.
    // Bubbles have varying heights, so this is an estimate — the exact
    // offset is refined by [_ensureVisible] once the item is laid out.
    final target = maxExtent * (messages.length - 1 - index) / messages.length;
    _scroll
        .animateTo(
          target.clamp(0.0, maxExtent),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        )
        .then((_) => _ensureVisible(id));
  }

  /// Snaps the viewport to the message once it has been built (the estimate
  /// above only gets close).
  void _ensureVisible(String id) {
    if (!mounted) return;
    final target = _messageKeys[id]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 200),
      alignment: 0.5,
    );
  }

  /// Reports the newest real message visible in the viewport (read ack).
  /// Called on scroll and after layout; the provider debounces the actual
  /// send and dedupes by id.
  void _reportNewestVisible() {
    if (!mounted || !_scroll.hasClients) return;
    widget.onNewestVisible?.call(_newestVisibleMessageId());
  }

  /// Newest message (by id, non-system, non-optimistic) with any part of
  /// its box inside the viewport. Iterates newest → oldest so the first hit
  /// is the newest visible one; items not yet laid out are skipped.
  String? _newestVisibleMessageId() {
    final messages = widget.state.messages;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox) return null;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      // Only real, readable messages count: system rows and optimistic
      // (unsent) bubbles have ids the server can't resolve.
      if (m.isSystem || m.id == null || m.pendingId != null) continue;
      final ctx = _messageKeys[m.id]?.currentContext;
      if (ctx == null) continue; // not laid out yet — keep scanning
      final box = ctx.findRenderObject();
      if (box is! RenderBox) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom > viewportTop && top < viewportBottom) return m.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.state.messages;
    final showLoadOlder =
        widget.onLoadOlder != null &&
        widget.state.hasMoreHistory &&
        messages.isNotEmpty;

    // Report the newest visible message after every layout (first frame,
    // new messages arriving, load-older, scroll settle) so read acks track
    // what's actually on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportNewestVisible());

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length + (showLoadOlder ? 1 : 0),
      itemBuilder: (context, index) {
        if (showLoadOlder && index == messages.length) {
          return _LoadOlderRow(
            isLoading: widget.state.isLoadingMore,
            error: widget.state.loadMoreError,
            onLoad: widget.onLoadOlder!,
          );
        }
        final message = messages[messages.length - 1 - index];
        final myId = widget.me?.clerkId;
        final isMine = myId != null && message.author?.clerkId == myId;
        final keyId = message.id ?? message.pendingId;
        final rowKey = keyId == null
            ? null
            : _messageKeys.putIfAbsent(keyId, () => GlobalKey());
        final bubble = MessageBubble(
          message: message,
          isMine: isMine,
          myUserId: myId,
          dictEntries: widget.dictEntries,
          onRetry: widget.onRetryMessage,
          onEdit: widget.onEdit,
          onDeleteForMe: widget.onDeleteForMe,
          onDeleteForEveryone: widget.onDeleteForEveryone,
          onSaveImage: widget.onSaveImage,
          onForward: widget.onForward,
          isDm: widget.isDm,
          highlighted: keyId != null && _highlighted.contains(keyId),
        );
        return rowKey == null ? bubble : KeyedSubtree(key: rowKey, child: bubble);
      },
    );
  }
}

/// "Load older messages" row: a tappable button while idle, a spinner
/// while loading, and the error with a retry when a fetch failed.
class _LoadOlderRow extends StatelessWidget {
  const _LoadOlderRow({
    required this.isLoading,
    required this.error,
    required this.onLoad,
  });

  final bool isLoading;
  final String? error;
  final Future<void> Function() onLoad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: TextButton.icon(
            onPressed: onLoad,
            icon: const Icon(Icons.refresh),
            label: Text(error!, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }

    return Center(
      child: TextButton.icon(
        onPressed: onLoad,
        icon: const Icon(Icons.keyboard_arrow_up),
        label: Text(
          'Load older messages',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

class EmptyRoom extends StatelessWidget {
  const EmptyRoom({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('No messages yet — say hi!'),
    );
  }
}
