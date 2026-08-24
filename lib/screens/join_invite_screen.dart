import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../providers/chat_list_provider.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';
import 'chat_room_screen.dart';

/// Join a room via an invite link / code (the guaranteed path for shared
/// invite links — no deep-link platform config required). Paste the code →
/// preview the room (`GET /chats/invite/:code`) → join (`POST .../join`) →
/// open the room. Already a member? The join endpoint reports it and the room
/// opens anyway.
class JoinInviteScreen extends ConsumerStatefulWidget {
  const JoinInviteScreen({super.key, this.initialCode});

  /// Pre-filled code (e.g. from a deep link).
  final String? initialCode;

  @override
  ConsumerState<JoinInviteScreen> createState() => _JoinInviteScreenState();
}

class _JoinInviteScreenState extends ConsumerState<JoinInviteScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialCode ?? '');
  ChatSearchResult? _preview;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _code => _controller.text.trim();

  Future<void> _fetchPreview() async {
    final code = _code;
    if (code.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info =
          await ref.read(chatsRepositoryProvider).getInviteInfo(code);
      if (!mounted) return;
      setState(() {
        _preview = info;
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _preview = null;
      });
    }
  }

  Future<void> _join() async {
    if (_busy) return;
    final code = _code;
    if (code.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(chatsRepositoryProvider).joinByCode(code);
      // The new room (or its unread change) appears in the chat list.
      ref.invalidate(chatListProvider);
      if (!mounted) return;
      showSnackVia(
        messenger,
        result.alreadyMember ? 'Already a member of that room' : 'Joined the room',
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatRoomScreen(
            chat: ChatSummary(
              id: result.chatId,
              name: _preview?.name,
              access: _preview?.access ?? 'private',
            ),
          ),
        ),
      );
    } on Exception catch (e) {
      if (mounted) showSnackVia(messenger, 'Could not join: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Join with invite link')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _controller,
            autofocus: widget.initialCode == null,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _fetchPreview(),
            decoration: InputDecoration(
              hintText: 'Paste an invite code',
              prefixIcon: const Icon(Icons.link),
              border: const OutlineInputBorder(),
              suffixIcon: _loading
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
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (_loading || _busy) ? null : _fetchPreview,
            icon: const Icon(Icons.search),
            label: const Text('Preview room'),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              _error!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          if (_preview case final ChatSearchResult room) ...[
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.meeting_room)),
                title: Text(room.name ?? 'Unnamed room'),
                subtitle: Text(
                  '${room.access ?? 'private'} · ${room.participantCount ?? 0} members',
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _join,
              icon: const Icon(Icons.login),
              label: const Text('Join room'),
            ),
          ],
        ],
      ),
    );
  }
}