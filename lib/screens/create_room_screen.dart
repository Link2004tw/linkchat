import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../providers/chat_list_provider.dart';
import '../providers/repository_providers.dart';
import '../utils/snack.dart';

/// Creates a group room (`POST /chats`) and pops with the created
/// [ChatSummary] so the caller can open it.
class CreateRoomScreen extends ConsumerStatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  ConsumerState<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends ConsumerState<CreateRoomScreen> {
  final TextEditingController _nameController = TextEditingController();
  String _access = 'public';
  bool _submitting = false;

  static const _accessDescriptions = <String, String>{
    'public': 'Anyone can find and join this room.',
    'protected': 'Joining requires admin approval.',
    'private': 'Only people you invite can join.',
  };

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Room name is required');
      return;
    }
    setState(() => _submitting = true);
    try {
      final chat = await ref
          .read(chatsRepositoryProvider)
          .createGroup(name: name, access: _access);
      ref.invalidate(chatListProvider);
      if (!mounted) return;
      Navigator.of(context).pop(chat);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showSnack(context, 'Could not create room: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Create room')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            maxLength: 50,
            decoration: const InputDecoration(
              labelText: 'Room name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Text('Who can join?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'public', label: Text('Public')),
              ButtonSegment(value: 'protected', label: Text('Protected')),
              ButtonSegment(value: 'private', label: Text('Private')),
            ],
            selected: {_access},
            onSelectionChanged: (selection) =>
                setState(() => _access = selection.first),
          ),
          const SizedBox(height: 8),
          Text(
            _accessDescriptions[_access] ?? '',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _submitting ? null : _create,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: const Text('Create room'),
          ),
        ],
      ),
    );
  }
}
