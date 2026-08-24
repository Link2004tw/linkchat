import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A full-width error-styled strip for transient status messages — e.g. a
/// WebSocket failure banner on the chat room and chat list screens.
///
/// Tapping it copies the message to the clipboard — handy for pasting a
/// connection error (with its target URL) into a bug report.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.text});

  final String text;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: InkWell(
        onTap: () => _copy(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Copy',
                child: Icon(
                  Icons.content_copy,
                  size: 14,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
