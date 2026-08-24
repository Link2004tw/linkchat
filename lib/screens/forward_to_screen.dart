import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../providers/chat_list_provider.dart';

/// Forward target picker: every chat the user belongs to, including the
/// current room. Tapping a chat pops with the chosen [ChatSummary]; the
/// caller sends the message via the forward endpoint.
class ForwardToScreen extends ConsumerWidget {
  const ForwardToScreen({super.key, required this.currentChatId});

  /// The chat the message is being forwarded out of.
  final String currentChatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chats = ref.watch(chatListProvider);
    final targets = chats.valueOrNull == null
        ? const <ChatSummary>[]
        : chats.valueOrNull!.toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('Forward to')),
      body: chats.isLoading && targets.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : targets.isEmpty
              ? const Center(child: Text('No chats to forward to'))
              : ListView.builder(
                  itemCount: targets.length,
                  itemBuilder: (context, index) {
                    final chat = targets[index];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.chat_outlined)),
                      title: Text(chat.displayName),
                      subtitle: Text(
                        chat.isDm
                            ? 'Direct message'
                            : '${chat.access} · ${chat.participantCount ?? 0} members',
                        style: theme.textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.of(context).pop(chat),
                    );
                  },
                ),
    );
  }
}