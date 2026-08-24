import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import '../utils/dialogs.dart';

class BlockedUsersScreen extends ConsumerStatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  ConsumerState<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends ConsumerState<BlockedUsersScreen> {
  List<Map<String, dynamic>> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(chatsRepositoryProvider).getBlocked();
      setState(() {
        _blocked = data;
        _loading = false;
      });
    } on Exception catch (e) {
      if (mounted) {
        showSnack(context, 'Failed to load blocked users: $e');
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _unblock(String clerkId, String username) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Unblock @$username?',
      message:
          'They will be able to see your profile and message you again.',
      confirmLabel: 'Unblock',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(userRepositoryProvider).unblockUser(clerkId);
      await _load();
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Unblock failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Users')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _blocked.isEmpty
              ? const Center(child: Text('No blocked users'))
              : ListView.builder(
                  itemCount: _blocked.length,
                  itemBuilder: (ctx, i) {
                    final user = _blocked[i];
                    final username = user['username'] as String? ?? 'Unknown';
                    final clerkId = user['clerkId'] as String? ?? '';
                    final imageUrl = user['profileImageUrl'] as String?;
                    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage:
                            hasImage ? NetworkImage(imageUrl) : null,
                        child: hasImage
                            ? null
                            : Text(username[0].toUpperCase()),
                      ),
                      title: Text(username),
                      trailing: TextButton(
                        onPressed: () => _unblock(clerkId, username),
                        child: const Text('Unblock'),
                      ),
                    );
                  },
                ),
    );
  }
}
