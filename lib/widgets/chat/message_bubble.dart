import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/markdown_util.dart';
import '../../models/content_types.dart';
import '../../models/dictionary.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../services/dictionary_crypto.dart';
import '../../utils/dialogs.dart';
import '../../utils/format.dart';
import '../../utils/snack.dart';
import '../user_avatar.dart';
import 'markdown_message.dart';
import 'media_bubbles.dart';
import 'user_profile_sheet.dart';

/// One row: a system message (centered) or a chat bubble. Code words are
/// shown as-is (opaque) until the bubble is tapped, which reveals meanings.
class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.myUserId,
    this.dictEntries = const [],
    this.onRetry,
    this.onEdit,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.onSaveImage,
    this.onForward,
    this.isDm = false,
    this.highlighted = false,
  });

  final ChatMessage message;
  final bool isMine;

  /// The signed-in user's Clerk id — used to mark messages that mention me.
  final String? myUserId;

  /// Code→meaning dictionary for tap-to-reveal.
  final List<DictEntry> dictEntries;

  /// True if the current user is typing in a DM — hides own typing indicator.
  final bool isDm;

  /// True while this message is a fresh search result (drawn with a
  /// highlight ring, cleared after a couple of seconds).
  final bool highlighted;

  /// Called with the message id when a failed optimistic message is tapped.
  final void Function(String messageId)? onRetry;

  /// Long-press actions ("Delete for me", "Delete for everyone" for own
  /// messages, "Save image" for image bubbles).
  final void Function(String messageId)? onDeleteForMe;
  final void Function(String messageId)? onDeleteForEveryone;
  final void Function(String url)? onSaveImage;

  /// Called with the message id when "Edit" is picked on an own text message.
  final void Function(String messageId)? onEdit;

  /// Called with the message id when "Forward" is picked — the caller opens
  /// the forward target picker and sends the message to the chosen chat.
  final void Function(String messageId)? onForward;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  /// True → show meanings instead of code words for this message.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isMine = widget.isMine;

    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.content,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      );
    }

    // Sender name shown only for other people's messages.
    final authorName = isMine ? null : message.author?.username;
    final bubbleColor =
        isMine ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final textColor =
        isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    final avatar = message.author == null
        ? null
        : UserAvatar(
            user: message.author!,
            radius: 16,
            onTap: () => openUserFromAvatar(
              context,
              ref,
              clerkId: message.author?.clerkId ?? message.author?.backendId,
              user: message.author,
            ),
          );
    final failed = message.sendFailed;
    final revealable = widget.dictEntries.isNotEmpty && !message.isSystem;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine && avatar != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 2, right: 2),
              child: avatar,
            ),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () {
                    if (failed && widget.onRetry != null) {
                      widget.onRetry!(message.pendingId ?? message.id ?? '');
                      return;
                    }
                    if (revealable) {
                      setState(() => _revealed = !_revealed);
                    }
                  },
                  onLongPress: message.isSystem ? null : _showActions,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.circular(16),
                      border: widget.highlighted
                          ? Border.all(color: theme.colorScheme.primary, width: 2)
                          : null,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (authorName != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  authorName,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: theme.colorScheme.primary),
                                ),
                                if (!isMine &&
                                    widget.myUserId != null &&
                                    message.mentionsMe(widget.myUserId!)) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'mentioned you',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color:
                                            theme.colorScheme.onPrimaryContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        if (message.forwardedFrom case final ForwardedFrom forwarded)
                          if (forwarded.authorId != widget.myUserId)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.reply,
                                    size: 12,
                                    color: textColor.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      'Forwarded from ${forwarded.username.isEmpty ? 'an unknown sender' : forwarded.username}',
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color: textColor.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        _Content(
                          message: message,
                          textColor: textColor,
                          dictEntries: widget.dictEntries,
                          revealed: _revealed,
                          isMine: widget.isMine,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${formatTime(message.createdAt ?? DateTime.now())}'
                            '${message.isEdited ? ' · edited' : ''}'
                            '${_revealed ? ' · hiding' : ''}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        if (isMine && message.seenBy.isNotEmpty)
                          // Tap (or long-press) the "Seen by" caption to
                          // open the reader detail sheet with exact read
                          // times. In DMs, show a simple "Seen" instead of
                          // listing usernames.
                          GestureDetector(
                            onTap: _showSeenByDetail,
                            onLongPress: _showSeenByDetail,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                widget.isDm
                                    ? 'Seen'
                                    : 'Seen by ${message.seenBy.length}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: textColor.withValues(alpha: 0.7),
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                        if (isMine && message.seenBy.isEmpty && widget.isDm)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Not seen',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: textColor.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(right: 14, top: 2),
                    child: Text(
                      'Not sent — tap to retry',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Long-press menu: delete-for-me on any real message, delete-for-everyone
  /// on my own, and save-image on image bubbles.
  /// Bottom sheet listing everyone who has seen this message, with the
  /// exact time each reader's cursor passed it (read receipts). Shown from
  /// the "Seen by …" caption (tap or long-press) on own messages.
  void _showSeenByDetail() {
    final readers = widget.message.seenByOldestFirst;
    if (readers.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Seen by ${readers.length}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: readers.length,
                itemBuilder: (ctx, i) {
                  final reader = readers[i];
                  final readAt = reader.lastReadAt;
                  return ListTile(
                    leading: UserAvatar(
                      user: ChatUser(
                        clerkId: reader.userId,
                        username: reader.username,
                      ),
                      radius: 18,
                    ),
                    title: Text(reader.username),
                    subtitle: Text(
                      readAt == null
                          ? 'Read'
                          : 'Read ${formatDate(readAt)} · ${formatTime(readAt)}',
                    ),
                    onTap: () => openUserFromAvatar(
                      ctx,
                      ref,
                      clerkId: reader.userId,
                      user: ChatUser(
                        clerkId: reader.userId,
                        username: reader.username,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showActions() {
    final message = widget.message;
    final id = message.id ?? message.pendingId;
    if (id == null) return;
    final isReal = message.pendingId == null;

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isReal)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _copyToClipboard();
                },
              ),
            if (isReal &&
                widget.isMine &&
                widget.onEdit != null &&
                !isMediaContentType(message.contentType))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onEdit!(id);
                },
              ),
            if (isReal && widget.onForward != null)
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onForward!(id);
                },
              ),
            if (isReal && widget.onDeleteForMe != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete for me'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onDeleteForMe!(id);
                },
              ),
            if (isReal && widget.isMine && widget.onDeleteForEveryone != null)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Delete for everyone'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmDeleteForEveryone();
                },
              ),
            if (isReal &&
                message.contentType == ContentTypes.image &&
                widget.onSaveImage != null)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Save image'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onSaveImage!(message.content);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteForEveryone() async {
    final id = widget.message.id;
    if (id == null) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Delete for everyone?',
      message:
          'This deletes the message for all members. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) widget.onDeleteForEveryone!(id);
  }

  /// "Copy": copies what you see — code words are expanded to their meanings
  /// when the chat has a dictionary, media copies the caption (or the raw
  /// URL when there is none). Client-only; nothing is sent to the server.
  Future<void> _copyToClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: messageCopyText(widget.message, widget.dictEntries)),
    );
    showSnackVia(messenger, 'Copied to clipboard');
  }
}

/// Renders the message body: text, or media (image/video/file) with caption.
class _Content extends StatelessWidget {
  const _Content({
    required this.message,
    required this.textColor,
    this.dictEntries = const [],
    this.revealed = false,
    this.isMine = false,
  });

  final ChatMessage message;
  final Color textColor;
  final List<DictEntry> dictEntries;
  final bool revealed;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    switch (message.contentType) {
      case ContentTypes.image:
        return _MediaContent(
          message: message,
          textColor: textColor,
          dictEntries: dictEntries,
          revealed: revealed,
          child: ImageMessage(url: message.content),
        );
      case ContentTypes.video:
        return _MediaContent(
          message: message,
          textColor: textColor,
          dictEntries: dictEntries,
          revealed: revealed,
          child: VideoMessage(url: message.content),
        );
      case ContentTypes.file:
        return _MediaContent(
          message: message,
          textColor: textColor,
          dictEntries: dictEntries,
          revealed: revealed,
          child: FileMessage(message: message),
        );
      case ContentTypes.audio:
        return _MediaContent(
          message: message,
          textColor: textColor,
          dictEntries: dictEntries,
          revealed: revealed,
          child: AudioMessage(url: message.content, isMine: isMine),
        );
      default:
        // Markdown always renders immediately — no press needed (even in
        // chats with a code-word dictionary). Tapping the bubble still
        // toggles reveal: hidden shows the codes literally inside the
        // formatted text, revealed expands them to their meanings.
        final expanded = revealed && dictEntries.isNotEmpty
            ? DictionaryCrypto.expandIncoming(message.content, dictEntries)
            : message.content;
        return MarkdownMessage(
          text: expanded,
          textColor: textColor,
          // Links sit on the bubble background: for own messages that's
          // `primary`, so links must use the on-primary contrast color or
          // they'd be invisible (primary-on-primary).
          linkColor: isMine
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.primary,
          mentionTokens: [
            if (message.mentionAll)
              const MentionToken(name: 'all', userId: 'all'),
            for (final m in message.mentions)
              MentionToken(name: m.username, userId: m.userId),
          ],
        );
    }
  }
}
/// Renders text, showing code words opaque by default and expandable via
/// [revealed]. Code words are underlined when hidden to hint they have a
/// private meaning.
class CodedText extends StatelessWidget {
  const CodedText({
    super.key,
    required this.text,
    required this.dictEntries,
    required this.revealed,
    this.style,
    this.highlightColor,
  });

  final String text;
  final List<DictEntry> dictEntries;
  final bool revealed;
  final TextStyle? style;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    if (dictEntries.isEmpty) return Text(text, style: style);
    final codes = {for (final e in dictEntries) e.code.trim()}
      ..removeWhere((c) => c.isEmpty);

    final content =
        revealed ? DictionaryCrypto.expandIncoming(text, dictEntries) : text;
    final TextStyle? baseStyle = style;

    if (revealed || codes.isEmpty) {
      return Text(content, style: baseStyle);
    }

    // When hidden, underline any code words so the tap-to-reveal affordance
    // is visible without leaking the meaning.
    final spans = <TextSpan>[];
    final pattern = RegExp(r'[^\s]+', unicode: true);
    var last = 0;
    for (final match in pattern.allMatches(content)) {
      if (match.start > last) {
        spans.add(TextSpan(text: content.substring(last, match.start)));
      }
      final word = content.substring(match.start, match.end);
      final stripped = word;
      if (codes.contains(stripped)) {
        spans.add(TextSpan(
          text: word,
          style: baseStyle?.copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dashed,
            fontWeight: FontWeight.w600,
            color: highlightColor ?? baseStyle.color,
          ),
        ));
      } else {
        spans.add(TextSpan(text: word));
      }
      last = match.end;
    }
    if (last < content.length) {
      spans.add(TextSpan(text: content.substring(last)));
    }
    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}

/// Wraps a media widget and shows the caption below it.
class _MediaContent extends StatelessWidget {
  const _MediaContent({
    required this.message,
    required this.textColor,
    this.dictEntries = const [],
    this.revealed = false,
    required this.child,
  });

  final ChatMessage message;
  final Color textColor;
  final List<DictEntry> dictEntries;
  final bool revealed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = message.caption;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        if (caption != null && caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          CodedText(
            text: caption,
            dictEntries: dictEntries,
            revealed: revealed,
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
          ),
        ],
      ],
    );
  }
}

