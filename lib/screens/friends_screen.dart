import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/chat.dart';
import '../models/friend.dart';
import '../providers/chat_list_provider.dart';
import '../providers/friends_providers.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import 'add_friends_screen.dart';
import 'chat_room_screen.dart';
import '../widgets/error_state.dart';
import '../utils/dialogs.dart';

/// Friends list with a one-tap DM shortcut (DM resolved on demand).
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: 'Add friends',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AddFriendsScreen()),
            ),
          ),
        ],
      ),
      body: friends.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          message: _friendlyError(error),
          onRetry: _retry,
        ),
        data: (list) => list.isEmpty
            ? const _EmptyFriends()
            : RefreshIndicator(
                onRefresh: () => ref.refresh(friendsProvider.future),
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final friend = list[index];
                    return _FriendTile(
                      friend: friend,
                      onTap: () => _openDm(context, friend),
                      onRemove: () => _confirmRemove(context, ref, friend),
                      onBlock: () => _confirmBlock(context, ref, friend),
                    );
                  },
                ),
              ),
      ),
    );
  }

  Future<void> _retry() async {
    ref.invalidate(friendsProvider);
  }

  Future<void> _openDm(BuildContext context, Friend friend) async {
    final clerkId = friend.clerkId;
    if (clerkId == null) {
      showSnack(context, 'Cannot open chat for this friend.');
      return;
    }

    // Show a loading indicator on the tile while resolving the DM.
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final dmChatId = await ref.read(friendsRepositoryProvider).getFriendDm(clerkId);

    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss loading dialog

    if (dmChatId == null) {
      debugPrint('[dm] Could not resolve DM for friend ${friend.displayName} ($clerkId) — user may not be a friend');
      showSnack(context, 'Could not open chat. Try again.');
      return;
    }

    ref.invalidate(chatListProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatRoomScreen(
          chat: ChatSummary(
            id: dmChatId,
            access: 'direct',
            otherUser: ChatOtherUser(
              clerkId: clerkId,
              name: friend.displayName,
              imageUrl: friend.profileImageUrl,
            ),
          ),
        ),
      ),
    );
  }
}

/// Converts raw errors into user-friendly messages.
String _friendlyError(Object error) {
  if (error is ApiException) {
    if (error.statusCode == null) return 'Connection failed. Check your internet.';
    if (error.statusCode == 500) return 'Server error. Please try again.';
    if (error.statusCode == 408) return 'Request timed out. Try again.';
    return 'Failed to load friends (${error.statusCode}).';
  }
  final msg = error.toString();
  if (msg.contains('timed out') || msg.contains('Timeout')) {
    return 'Request timed out. Try again.';
  }
  if (msg.contains('SocketException') || msg.contains('Connection')) {
    return 'Connection failed. Check your internet.';
  }
  return 'Could not load friends.';
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({
    required this.friend,
    required this.onTap,
    required this.onRemove,
    required this.onBlock,
  });

  final Friend friend;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = friend.profileImageUrl;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundImage: hasImage ? NetworkImage(imageUrl) : null,
        child: hasImage
            ? null
            : Text(friend.displayName.isNotEmpty
                ? friend.displayName[0].toUpperCase()
                : '?'),
      ),
      title: Text(friend.displayName),
      subtitle: Text('@${friend.username}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'remove') onRemove();
              if (value == 'block') onBlock();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'remove',
                child: Text('Remove friend'),
              ),
              PopupMenuItem<String>(
                value: 'block',
                child: Text('Block', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows a confirm dialog, then calls `DELETE /user/friends/:clerkId` and
/// refreshes the list.
Future<void> _confirmRemove(
  BuildContext context,
  WidgetRef ref,
  Friend friend,
) async {
  final confirmed = await confirmDialog(
    context,
    title: 'Remove friend?',
    message:
        '${friend.displayName} will be removed from your friends. '
        'This cannot be undone.',
    confirmLabel: 'Remove',
  );
  if (!confirmed || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final clerkId = friend.clerkId;
  if (clerkId == null) {
    showSnackVia(messenger, 'Could not remove this friend.');
    return;
  }

  try {
    await ref.read(friendsRepositoryProvider).removeFriend(clerkId);
    ref.invalidate(friendsProvider);
    ref.invalidate(chatListProvider);
    showSnackVia(messenger, '${friend.displayName} removed.');
  } on Exception {
    showSnackVia(messenger, 'Could not remove friend. Try again.');
  }
}

Future<void> _confirmBlock(
  BuildContext context,
  WidgetRef ref,
  Friend friend,
) async {
  final confirmed = await confirmDialog(
    context,
    title: 'Block ${friend.displayName}?',
    message:
        'They won\'t be able to see your profile or message you. '
        'This can be undone from your profile.',
    confirmLabel: 'Block',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final clerkId = friend.clerkId;
  if (clerkId == null) {
    showSnackVia(messenger, 'Could not block this user.');
    return;
  }

  try {
    await ref.read(userRepositoryProvider).blockUser(clerkId);
    ref.invalidate(friendsProvider);
    ref.invalidate(chatListProvider);
    showSnackVia(messenger, '${friend.displayName} blocked.');
  } on Exception {
    showSnackVia(messenger, 'Could not block user. Try again.');
  }
}

class _EmptyFriends extends StatelessWidget {
  const _EmptyFriends();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64),
          SizedBox(height: 12),
          Text('No friends yet'),
          SizedBox(height: 4),
          Text('Use the + icon to find and add people.'),
        ],
      ),
    );
  }
}

