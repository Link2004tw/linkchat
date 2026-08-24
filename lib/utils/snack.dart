import 'package:flutter/material.dart';

/// Shows a plain [SnackBar] with the given [message] via the root
/// [ScaffoldMessenger]. Kept as one helper so every screen shows the same
/// snack style instead of copy-pasting `ScaffoldMessenger...showSnackBar`.
void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// Same as [showSnack] but takes an already-looked-up [ScaffoldMessengerState]
/// — for handlers that must capture the messenger before an `await` (stays
/// `use_build_context_synchronously`-clean).
void showSnackVia(ScaffoldMessengerState messenger, String message) {
  messenger.showSnackBar(SnackBar(content: Text(message)));
}