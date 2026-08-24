import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/friend_request.dart';
import '../providers/chat_list_provider.dart';
import '../providers/friends_providers.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import '../widgets/error_state.dart';

/// Pending friend requests: incoming (accept/decline) and outgoing (cancel).
class RequestsScreen extends ConsumerStatefulWidget {
  const RequestsScreen({super.key});

  @override
  ConsumerState<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends ConsumerState<RequestsScreen> {
  final Set<String> _busy = {};

  Future<void> _run(String requestId, Future<void> Function() action) async {
    if (_busy.contains(requestId)) return;
    setState(() => _busy.add(requestId));
    try {
      await action();
    } on Exception catch (e) {
      if (mounted) {
        showSnack(context, 'Failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  void _accept(FriendRequest request) {
    _run(request.id, () async {
      await ref.read(friendsRepositoryProvider).acceptRequest(request.id);
      ref.invalidate(friendRequestsProvider);
      ref.invalidate(friendsProvider);
      // Accepting auto-creates the DM — surface it in the chat list too.
      ref.invalidate(chatListProvider);
    });
  }

  void _decline(FriendRequest request) {
    _run(request.id, () async {
      await ref.read(friendsRepositoryProvider).declineRequest(request.id);
      ref.invalidate(friendRequestsProvider);
    });
  }

  void _cancel(FriendRequest request) {
    _run(request.id, () async {
      await ref.read(friendsRepositoryProvider).cancelRequest(request.id);
      ref.invalidate(friendRequestsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(friendRequestsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Requests')),
      body: requests.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          message: 'Could not load requests\n$error',
          onRetry: () => ref.invalidate(friendRequestsProvider),
        ),
        data: (data) {
          if (data.ingoing.isEmpty && data.outgoing.isEmpty) {
            return const Center(child: Text('No pending requests.'));
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(friendRequestsProvider.future),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (data.ingoing.isNotEmpty) ...[
                  const _SectionHeader('Incoming'),
                  for (final request in data.ingoing)
                    _IncomingTile(
                      request: request,
                      busy: _busy.contains(request.id),
                      onAccept: () => _accept(request),
                      onDecline: () => _decline(request),
                    ),
                ],
                if (data.outgoing.isNotEmpty) ...[
                  const _SectionHeader('Outgoing'),
                  for (final request in data.outgoing)
                    _OutgoingTile(
                      request: request,
                      busy: _busy.contains(request.id),
                      onCancel: () => _cancel(request),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _IncomingTile extends StatelessWidget {
  const _IncomingTile({
    required this.request,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final FriendRequest request;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = request.from;
    final imageUrl = user.profileImageUrl;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundImage: hasImage ? NetworkImage(imageUrl) : null,
        child: hasImage
            ? null
            : Text(user.displayName.isNotEmpty
                ? user.displayName[0].toUpperCase()
                : '?'),
      ),
      title: Text(user.displayName),
      subtitle: Text(request.message ?? 'wants to be friends'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: busy ? null : onAccept,
            child: const Text('Accept'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: busy ? null : onDecline,
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }
}

class _OutgoingTile extends StatelessWidget {
  const _OutgoingTile({
    required this.request,
    required this.busy,
    required this.onCancel,
  });

  final FriendRequest request;
  final bool busy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = request.to;
    final imageUrl = user.profileImageUrl;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundImage: hasImage ? NetworkImage(imageUrl) : null,
        child: hasImage
            ? null
            : Text(user.displayName.isNotEmpty
                ? user.displayName[0].toUpperCase()
                : '?'),
      ),
      title: Text(user.displayName),
      subtitle: const Text('Pending'),
      trailing: OutlinedButton(
        onPressed: busy ? null : onCancel,
        child: const Text('Cancel'),
      ),
    );
  }
}
