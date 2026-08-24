import 'package:flutter/material.dart';

/// Shared text-prompt dialog: an [AlertDialog] with a single [TextField]
/// plus Cancel / [confirmLabel] actions. Returns the entered text, or null
/// when cancelled.
///
/// Callers decide whether to trim — the raw field value is returned so
/// prompts that care about whitespace keep their own semantics.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? labelText,
  String? hintText,
  String initial = '',
  int? maxLength,
  int maxLines = 1,
  int? minLines,
  TextCapitalization textCapitalization = TextCapitalization.none,

  /// Label for the confirm button, e.g. 'Save', 'OK', 'Rename'.
  required String confirmLabel,

  /// When given, the confirm button stays disabled until this returns true
  /// for the current value.
  bool Function(String value)? validate,

  /// Whether pressing enter on the keyboard submits the dialog with the
  /// current text (used by simple single-line prompts).
  bool submitOnEnter = false,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
        maxLines: maxLines,
        minLines: minLines,
        textCapitalization: textCapitalization,
        decoration: InputDecoration(labelText: labelText, hintText: hintText),
        onSubmitted: submitOnEnter
            ? (v) => Navigator.of(dialogContext).pop(v)
            : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (ctx, value, _) {
            final valid = validate == null || validate(value.text);
            return FilledButton(
              onPressed: valid
                  ? () => Navigator.of(dialogContext).pop(controller.text)
                  : null,
              child: Text(confirmLabel),
            );
          },
        ),
      ],
    ),
  );
}

/// Shared confirmation dialog: Cancel + a confirm [FilledButton]. Returns
/// true only when the confirm button was pressed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',

  /// Draws the confirm button in error red (destructive actions).
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Colors.red)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
