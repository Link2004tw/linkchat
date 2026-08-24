import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user.dart';
import '../providers/chat_list_provider.dart';
import '../providers/friends_providers.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import '../widgets/error_state.dart';

/// Global user search with per-result actions driven by the backend's
/// `friendRequestStatus`: none → Add, pending → Cancel, respond →
/// Accept/Decline, friends → label.
class AddFriendsScreen extends ConsumerStatefulWidget {
  const AddFriendsScreen({super.key});

  @override
  ConsumerState<AddFriendsScreen> createState() => _AddFriendsScreenState();
}

class _AddFriendsScreenState extends ConsumerState<AddFriendsScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<UserSearchResult> _results = const [];
  final Set<String> _busy = {};
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _results = const [];
        _searching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results =
          await ref.read(userRepositoryProvider).searchUsers(query.trim());
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _searching = false;
      });
    }
  }

  Future<void> _run(String clerkId, Future<void> Function() action) async {
    if (_busy.contains(clerkId)) return;
    setState(() => _busy.add(clerkId));
    try {
      await action();
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(clerkId));
    }
  }

  void _sendRequest(UserSearchResult result) {
    final clerkId = result.user.clerkId!;
    _run(clerkId, () async {
      final requestId =
          await ref.read(friendsRepositoryProvider).sendRequest(clerkId);
      _update(result.user.clerkId!, 'pending', requestId: requestId);
    });
  }

  void _cancelRequest(UserSearchResult result) {
    final requestId = result.friendRequestId;
    if (requestId == null) return;
    _run(result.user.clerkId!, () async {
      await ref.read(friendsRepositoryProvider).cancelRequest(requestId);
      _update(result.user.clerkId!, 'none');
    });
  }

  void _acceptRequest(UserSearchResult result) {
    final requestId = result.friendRequestId;
    if (requestId == null) return;
    _run(result.user.clerkId!, () async {
      await ref.read(friendsRepositoryProvider).acceptRequest(requestId);
      _update(result.user.clerkId!, 'friends');
      ref.invalidate(friendsProvider);
      ref.invalidate(friendRequestsProvider);
      // Accepting auto-creates the DM — surface it in the chat list too.
      ref.invalidate(chatListProvider);
    });
  }

  void _declineRequest(UserSearchResult result) {
    final requestId = result.friendRequestId;
    if (requestId == null) return;
    _run(result.user.clerkId!, () async {
      await ref.read(friendsRepositoryProvider).declineRequest(requestId);
      _update(result.user.clerkId!, 'none');
      ref.invalidate(friendRequestsProvider);
    });
  }

  void _update(String clerkId, String status, {String? requestId}) {
    if (!mounted) return;
    setState(() {
      _results = [
        for (final r in _results)
          if (r.user.clerkId == clerkId)
            UserSearchResult(
              user: r.user,
              friendRequestStatus: status,
              friendRequestId: requestId,
            )
          else
            r,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add friends')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by name or username…',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ErrorState(message: _error!),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _searchController.text.trim().length < 2
              ? 'Type at least 2 characters to search.'
              : 'No users found.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return _UserTile(
          result: result,
          busy: _busy.contains(result.user.clerkId),
          onSend: () => _sendRequest(result),
          onCancel: () => _cancelRequest(result),
          onAccept: () => _acceptRequest(result),
          onDecline: () => _declineRequest(result),
        );
      },
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.result,
    required this.busy,
    required this.onSend,
    required this.onCancel,
    required this.onAccept,
    required this.onDecline,
  });

  final UserSearchResult result;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = result.user;
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
      subtitle: Text('@${user.username}'),
      trailing: switch (result.friendRequestStatus) {
        'friends' => const Text('Friends'),
        'pending' => OutlinedButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Cancel'),
          ),
        'respond' => Row(
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
        _ => FilledButton(
            onPressed: busy ? null : onSend,
            child: const Text('Add'),
          ),
      },
    );
  }
}
