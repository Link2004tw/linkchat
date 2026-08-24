import 'package:flutter/material.dart';

import '../../models/user.dart';


/// "Alice is typing…" / "Alice, Bob are typing…"
class TypingBanner extends StatelessWidget {
  const TypingBanner({
    super.key,
    required this.typingUserIds,
    required this.onlineUsers,
  });

  final Set<String> typingUserIds;
  final Map<String, ChatUser> onlineUsers;

  @override
  Widget build(BuildContext context) {
    if (typingUserIds.isEmpty) return const SizedBox.shrink();
    final names = typingUserIds
        .map((id) => onlineUsers[id]?.username ?? 'Someone')
        .toList();
    final label = names.length == 1
        ? '${names.first} is typing…'
        : '${names.join(', ')} are typing…';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(fontStyle: FontStyle.italic),
        ),
      ),
    );
  }
}
