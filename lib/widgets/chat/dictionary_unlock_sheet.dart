import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/dictionary_provider.dart';

/// Bottom sheet to unlock a passphrase-locked ("locked-v1") chat
/// dictionary. Shows a passphrase field plus, optionally, an owner escape
/// hatch: resetting the lock key starts the dictionary over under a new
/// passphrase without knowing the old one.
///
/// Pops with `true` when the dictionary ended up unlocked.
Future<bool> showDictionaryUnlockSheet(
  BuildContext context, {
  required String chatId,
  bool canReset = false,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _UnlockSheet(chatId: chatId, canReset: canReset),
  );
  return result ?? false;
}

class _UnlockSheet extends ConsumerStatefulWidget {
  const _UnlockSheet({required this.chatId, required this.canReset});

  final String chatId;
  final bool canReset;

  @override
  ConsumerState<_UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends ConsumerState<_UnlockSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showReset = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref
        .read(dictionaryProvider(widget.chatId).notifier)
        .unlock(_controller.text);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.error ?? 'Wrong passphrase';
    });
  }

  Future<void> _resetLockKey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref
        .read(dictionaryProvider(widget.chatId).notifier)
        .resetLockKey(_controller.text);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.error ?? 'Could not reset lock';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          // Keep the field above the keyboard.
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This chat’s code words are locked',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the shared passphrase to reveal meanings and edit '
              'the dictionary. You’ll need it again next time the app starts.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              enabled: !_busy,
              onSubmitted: (_) => _unlock(),
              decoration: InputDecoration(
                labelText: 'Passphrase',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _unlock,
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Unlock'),
            ),
            if (widget.canReset) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _showReset = !_showReset),
                child: Text(
                  _showReset
                      ? 'Hide reset options'
                      : 'Forgot the passphrase? Owner reset…',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              if (_showReset) ...[
                Text(
                  'Owner reset sets a NEW passphrase (type it above) and '
                  'starts the dictionary over with no code words. Everyone '
                  'must re-enter it and re-add their words.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _resetLockKey,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset & start over'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
