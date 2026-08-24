import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/join_invite_screen.dart';
import 'app_navigator.dart';

/// Extracts an invite code from a deep link:
/// - `https://<host>/join/<code>`
/// - `chatapp://join/<code>`
///
/// Returns null when the link isn't a join link.
String? inviteCodeFromUri(Uri? uri) {
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (uri.host == 'join') return segments.isEmpty ? null : segments.first;
  if (segments.isNotEmpty && segments.first == 'join') {
    return segments.length > 1 ? segments[1] : null;
  }
  return null;
}

/// Holds an invite code captured from a deep link while the user is signed
/// out. [consumePendingInvite] reads (and clears) it after sign-in.
final pendingInviteCodeProvider = StateProvider<String?>((ref) => null);

/// Starts the `app_links` listener (called by watching [deepLinkInitProvider]
/// from AuthGate). Best-effort: unsupported platforms and cold-start misses
/// are fine — the pasteable-code path in JoinInviteScreen always works.
Future<void> initDeepLinks(Ref ref) async {
  try {
    if (kIsWeb) {
      // On web the "initial link" is the page URL: app_links has no reliable
      // web implementation (getInitialLink throws MissingPluginException), so
      // read the URL directly. Navigating to `https://host/join/<code>`
      // serves this app and lands on the join screen.
      _park(ref, inviteCodeFromUri(Uri.base));
      return;
    }
    final appLinks = AppLinks();
    // Cold start: the link that launched the app (often absent).
    _park(ref, inviteCodeFromUri(await appLinks.getInitialLink()));
    _linkSub = appLinks.uriLinkStream.listen(
      (uri) => _park(ref, inviteCodeFromUri(uri)),
    );
    ref.onDispose(() => _linkSub?.cancel());
  } catch (e) {
    debugPrint('deep links unavailable: $e');
  }
}

StreamSubscription<Uri>? _linkSub;

void _park(Ref ref, String? code) {
  if (code == null || code.isEmpty) return;
  ref.read(pendingInviteCodeProvider.notifier).state = code;
}

/// Reading this provider (from AuthGate's build) starts the deep-link
/// listener once for the app's lifetime; the value is irrelevant.
final deepLinkInitProvider = Provider<void>((ref) {
  initDeepLinks(ref);
});

/// After sign-in: if a deep-link invite code was parked while signed out,
/// clear it and open the join screen with the code pre-filled.
void consumePendingInvite(WidgetRef ref) {
  final code = ref.read(pendingInviteCodeProvider);
  if (code == null || code.isEmpty) return;
  ref.read(pendingInviteCodeProvider.notifier).state = null;
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => JoinInviteScreen(initialCode: code),
    ),
  );
}