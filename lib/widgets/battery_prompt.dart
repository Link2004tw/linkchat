// One-time battery-optimization prompt (Android only).
//
// On OEM phones (Xiaomi, Samsung, Oppo, …), swiping the app from recents
// blocks FCM delivery entirely. The doze whitelist is the fix; this shows
// a bottom sheet once after sign-in asking the user to grant it. Dismissal
// is persisted, so we never nag twice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/theme_provider.dart';
import '../services/battery_optimization.dart';bool _shownThisSession = false;

/// Shows the exemption sheet when all of these hold: Android, not yet
/// exempted, not previously dismissed. Safe to call on every sign-in.
Future<void> maybeShowBatteryPrompt(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_shownThisSession) return;
  _shownThisSession = true;

  if (!await isIgnoringBatteryOptimizations()) {
    if (!context.mounted) return;
    await showBatterySheet(context, ref);
  }
}

/// The sheet itself — also used by the ProfileScreen's manual entry point.
Future<void> showBatterySheet(BuildContext context, WidgetRef ref) async {
  final hint = manufacturerHint(await deviceManufacturer());
  if (!context.mounted) return;
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.battery_saver, size: 40),
            const SizedBox(height: 12),
            Text(
              'Receive messages when the app is closed?',
              style: Theme.of(sheetContext).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Some phones stop message delivery for apps you swipe away. '
              'Allowing background activity fixes this — one tap, once.',
              textAlign: TextAlign.center,
              style: Theme.of(sheetContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(sheetContext)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                hint,
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                requestIgnoreBatteryOptimizations();
              },
              child: const Text('Allow'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                ref.read(themePrefsProvider).dismissBatteryPrompt();
                Navigator.of(sheetContext).pop();
              },
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
}
