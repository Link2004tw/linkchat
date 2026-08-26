import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_list_provider.dart';
import '../providers/repository_providers.dart';
import '../utils/format.dart';
import '../utils/snack.dart';
import '../widgets/status_banner.dart';
import '../widgets/user_avatar.dart';
import 'chat_room_screen.dart';
import 'create_room_screen.dart';
import 'join_room_screen.dart';
import 'profile_screen.dart';
import '../widgets/error_state.dart';
import '../models/content_types.dart';

/// The chat list: REST fetch (`GET /chats/all`) kept live by the
/// chat-list WebSocket (`new-message`, `unread-update`, ...).
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final me = ref.watch(currentUserProvider);
    final connection = ref.watch(chatListConnectionProvider);

    // Show the banner once the socket has dropped or failed — the initial
    // connect is silent so a fresh launch doesn't flash a warning.
    final showConnectionBanner =
        connection.attempts > 0 || connection.lastError != null;
    final connectionText = connection.lastError == null
        ? 'Connection lost — reconnecting…'
        : 'Connection lost — reconnecting…\n'
            '${connection.lastError!.message} (${connection.lastError!.url})';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
              ),
              child: me == null
                  ? const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.person_outline),
                    )
                  : UserAvatar(user: me, radius: 18),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewChatSheet(context, ref),
        tooltip: 'New chat',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (showConnectionBanner) StatusBanner(text: connectionText),
          Expanded(
            child: chats.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ErrorState(
                message: 'Could not load chats\n$error',
                onRetry: () => ref.invalidate(chatListProvider),
              ),
              data: (list) => list.isEmpty
                  ? const _EmptyState()
                  : RefreshIndicator(
                      onRefresh: () async {
                        try {
                          await ref.read(chatListProvider.notifier).refresh();
                        } on Exception {
                          // Keep showing the stale list; a failed refresh is
                          // not fatal for the user.
                        }
                      },
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: list.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 72),
                        itemBuilder: (context, index) {
                          final chat = list[index];
                          return _ChatTile(
                            chat: chat,
                            onTap: () {
                              ref.read(markChatAsReadProvider)(chat.id);
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ChatRoomScreen(chat: chat),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat, required this.onTap});

  final ChatSummary chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final last = chat.lastMessage;
    final mediaUrl = last?.mediaUrl;
    final showThumbnail = last?.contentType == ContentTypes.image &&
        mediaUrl != null &&
        mediaUrl.isNotEmpty;
    final preview = last == null
        ? 'No messages yet'
        : '${last.senderName == null ? '' : '${last.senderName}: '}${last.previewText}';

    return ListTile(
      onTap: onTap,
      onLongPress: () => _showMuteSheet(context, ref),
      leading: _ChatAvatar(chat: chat),
      title: Text(
        chat.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Row(
        children: [
          if (showThumbnail) ...[
            _Thumbnail(url: mediaUrl),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: _Trailing(chat: chat),
    );
  }

  /// Long-press menu: mute notifications for a chosen duration (8h / 1 day /
  /// 1 week / Forever), or unmute when already muted. Mute is
  /// notifications-only — reading/sending are never affected.
  Future<void> _showMuteSheet(BuildContext context, WidgetRef ref) async {
    final action = chat.mutedByUser ? 'unmute' : await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Mute notifications for…'),
            ),
            for (final entry in const [
              ('Mute for 8 hours', 'mute:8h'),
              ('Mute for 1 day', 'mute:1d'),
              ('Mute for 1 week', 'mute:1w'),
              ('Mute forever', 'mute:forever'),
            ])
              ListTile(
                title: Text(entry.$1),
                onTap: () => Navigator.of(sheetContext).pop(entry.$2),
              ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final repo = ref.read(chatsRepositoryProvider);
    try {
      if (action == 'unmute') {
        await repo.unmuteSelf(chat.id);
        ref.read(chatListProvider.notifier).setSelfMuted(chat.id, false);
      } else {
        await repo.muteSelf(chat.id, duration: action.split(':').last);
        ref.read(chatListProvider.notifier).setSelfMuted(chat.id, true);
      }
    } on Exception catch (e) {
      if (context.mounted) showSnack(context, 'Could not update mute: $e');
    }
  }
}

/// Small rounded thumbnail for image last-messages in the chat list.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: 28,
      height: 28,
      color: theme.colorScheme.surfaceContainerHighest,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 28,
        height: 28,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => Container(
          width: 28,
          height: 28,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.image_outlined,
            size: 16,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({required this.chat});

  final ChatSummary chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = chat.lastMessage?.sentAt ?? chat.updatedAt;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Self-mute indicator: notifications silenced for this chat.
        // Unread badges keep counting (mute ≠ hide).
        if (last != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chat.mutedByUser)
                Icon(
                  Icons.notifications_off,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
              if (chat.mutedByUser) const SizedBox(width: 3),
              Text(
                formatTime(last),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        const SizedBox(height: 4),
        // A mention badge replaces the plain unread badge when this chat
        // has unread messages that mention me — the `@` makes it stand out
        // from the usual count.
        if (chat.mentionedCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '@${chat.mentionedCount > 99 ? '99+' : chat.mentionedCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onTertiary,
              ),
            ),
          )
        else if (chat.unreadCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
      ],
    );
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.chat});

  final ChatSummary chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = chat.isDm
        ? chat.otherUser?.imageUrl
        : chat.pictureUrl;
    final initial = chat.displayName.isNotEmpty
        ? chat.displayName[0].toUpperCase()
        : '?';

    return CircleAvatar(
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundImage:
          (imageUrl != null && imageUrl.isNotEmpty) ? NetworkImage(imageUrl) : null,
      child: (imageUrl == null || imageUrl.isEmpty)
          ? Text(initial)
          : null,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('No chats yet'),
          const SizedBox(height: 4),
          Text(
            'Create or join a room to start chatting.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with the two ways to start chatting: create or join.
Future<void> _showNewChatSheet(BuildContext context, WidgetRef ref) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('Create a room'),
            subtitle: const Text('Start a new group room'),
            onTap: () => Navigator.of(sheetContext).pop('create'),
          ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Find a room'),
            subtitle: const Text('Search and join existing rooms'),
            onTap: () => Navigator.of(sheetContext).pop('join'),
          ),
        ],
      ),
    ),
  );

  if (!context.mounted) return;
  switch (action) {
    case 'create':
      final created = await Navigator.of(context).push<ChatSummary>(
        MaterialPageRoute(builder: (_) => const CreateRoomScreen()),
      );
      if (created != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatRoomScreen(chat: created),
          ),
        );
      }
    case 'join':
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const JoinRoomScreen()),
      );
  }
}

