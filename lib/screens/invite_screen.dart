import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/user.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import '../widgets/user_avatar.dart';
import '../widgets/error_state.dart';

/// Search users and invite them into a room. Entry is restricted to admins
/// of non-DM rooms by the caller (RoomDetailsScreen). The screen stays open
/// so an admin can invite several people in one visit.
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<UserSearchResult> _results = const [];
  final Set<String> _busy = {};
  final Set<String> _invited = {};
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
      final results = await ref
          .read(userRepositoryProvider)
          .searchUsers(query.trim());
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

  Future<void> _invite(UserSearchResult result) async {
    final username = result.user.username;
    if (_busy.contains(username)) return;
    setState(() => _busy.add(username));
    try {
      await ref.read(chatsRepositoryProvider).invite(widget.chatId, username);
      if (!mounted) return;
      setState(() => _invited.add(username));
      showSnack(context, 'Invited @$username');
    } on Exception catch (e) {
      if (mounted) showSnack(context, _inviteError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(username));
    }
  }

  /// Maps the backend's invite errors to a user-facing message:
  /// 404 → user/chat missing, 400 → already in the room, 403 → no permission
  /// (non-admin, or — since Phase 16 — inviting someone who isn't a friend).
  String _inviteError(Object error) {
    if (error is ApiException) {
      return switch (error.statusCode) {
        404 => 'User not found',
        400 => 'Already in the room',
        403 => () {
            if (error.message.contains('friends')) {
              debugPrint('[invite] User attempted to invite to room ${widget.chatId} but they are not friends (403 Forbidden)');
              return 'Only friends can be invited to rooms';
            }
            return 'Only admins can invite';
          }(),
        _ => 'Invite failed: ${error.message}',
      };
    }
    return 'Invite failed: $error';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Invite to room')),
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
        final username = result.user.username;
        final invited = _invited.contains(username);
        return ListTile(
          leading: UserAvatar(user: result.user, radius: 20),
          title: Text(result.user.displayName),
          subtitle: Text('@$username'),
          trailing: invited
              ? const Chip(
                  label: Text('Invited'),
                  visualDensity: VisualDensity.compact,
                )
              : FilledButton(
                  onPressed: _busy.contains(username)
                      ? null
                      : () => _invite(result),
                  child: const Text('Invite'),
                ),
        );
      },
    );
  }
}
