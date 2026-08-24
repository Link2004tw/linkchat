import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../providers/chat_list_provider.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import 'chat_room_screen.dart';
import 'join_invite_screen.dart';
import '../widgets/error_state.dart';

/// Finds public/protected rooms (`GET /chats/search`) and joins them
/// (`POST /chats/:id/join`) or requests to join protected ones.
class JoinRoomScreen extends ConsumerStatefulWidget {
  const JoinRoomScreen({super.key});

  @override
  ConsumerState<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends ConsumerState<JoinRoomScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<ChatSearchResult> _results = const [];
  final Set<String> _requested = {};
  bool _searching = false;
  String? _error;
  bool _busy = false;

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
          await ref.read(chatsRepositoryProvider).search(query.trim());
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

  Future<void> _join(ChatSearchResult room) async {
    if (_busy) return;
    _busy = true;
    try {
      if (room.access == 'protected') {
        await ref.read(chatsRepositoryProvider).joinRequest(room.chatId);
        if (!mounted) return;
        setState(() => _requested.add(room.chatId));
        showSnack(context, 'Join request sent — waiting for approval');
      } else {
        await ref.read(chatsRepositoryProvider).join(room.chatId);
        ref.invalidate(chatListProvider);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatRoomScreen(
              chat: ChatSummary(
                id: room.chatId,
                name: room.name,
                access: room.access ?? 'public',
              ),
            ),
          ),
        );
      }
    } on Exception catch (e) {
      if (!mounted) return;
      showSnack(context, 'Could not join: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find a room')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search rooms…',
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
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Join with invite link / code'),
            subtitle: const Text('Paste an invite code to join a private room'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const JoinInviteScreen()),
            ),
          ),
          const Divider(),
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
              : 'No rooms found.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final room = _results[index];
        final isRequested =
            _requested.contains(room.chatId) || room.isRequested == true;
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.meeting_room)),
          title: Text(room.name ?? 'Unnamed room'),
          subtitle: Text(
            '${room.access} · ${room.participantCount ?? 0} members',
          ),
          trailing: isRequested
              ? const Text('Requested')
              : room.access == 'protected'
                  ? OutlinedButton(
                      onPressed: () => _join(room),
                      child: const Text('Request'),
                    )
                  : FilledButton(
                      onPressed: () => _join(room),
                      child: const Text('Join'),
                    ),
          onTap: () => _join(room),
        );
      },
    );
  }
}
