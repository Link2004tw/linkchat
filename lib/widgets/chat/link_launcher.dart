import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/deep_link.dart';
import '../../screens/join_invite_screen.dart';
import '../../utils/snack.dart';

/// Opens a link from chat content. Custom `chatapp://` invite URLs navigate
/// in-app (join flow); everything else launches in the external browser,
/// with a snack on failure.
Future<void> openUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  final inviteCode = inviteCodeFromUri(uri);
  if (inviteCode != null) {
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JoinInviteScreen(initialCode: inviteCode),
      ),
    );
    return;
  }
  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );
  if (!ok && context.mounted) {
    showSnack(context, 'Could not open URL');
  }
}