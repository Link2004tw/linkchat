import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../utils/format.dart';
import '../user_avatar.dart';

/// bottom sheet with a live filter over the loaded messages. Pops with the
/// picked message's id (or null when dismissed).
class MessageSearchSheet extends StatefulWidget {
  const MessageSearchSheet({super.key, required this.messages});

  /// The currently loaded messages (oldest → newest).
  final List<ChatMessage> messages;

  @override
  State<MessageSearchSheet> createState() => MessageSearchSheetState();
}

class MessageSearchSheetState extends State<MessageSearchSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Live-filtered matches, like the web app: text messages match on their
  /// content, media messages on their caption.
  List<ChatMessage> get _results {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return [
      for (final m in widget.messages)
        if (m.contentType == 'text'
            ? m.content.toLowerCase().contains(query)
            : (m.caption?.toLowerCase().contains(query) ?? false))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    return Padding(
      // Keep the field above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Search in this chat…',
                    prefixIcon: Icon(Icons.search),
                    border: InputBorder.none,
                  ),
                ),
              ),
              if (_query.text.trim().isEmpty)
                const SizedBox(height: 96)
              else if (results.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No messages found',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      results.length == 1
                          ? '1 result'
                          : '${results.length} results',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final message = results[index];
                      final id = message.id ?? message.pendingId ?? '';
                      return ListTile(
                        leading: message.author == null
                            ? null
                            : UserAvatar(user: message.author!, radius: 16),
                        title: Text(
                          message.contentType == 'text'
                              ? message.content
                              : (message.caption ??
                                  'Sent a ${message.contentType}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${message.author?.username ?? 'Unknown'} · '
                          '${formatDate(message.createdAt ?? DateTime.now())}',
                          style: theme.textTheme.bodySmall,
                        ),
                        onTap: () => Navigator.of(context).pop(id),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

  }
}
