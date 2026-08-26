import 'dart:io';

import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/user.dart';
import '../providers/auth_providers.dart';
import '../providers/repository_providers.dart';
import '../providers/theme_provider.dart';
import '../utils/format.dart';
import '../utils/dialogs.dart';
import '../utils/media_picker.dart';
import '../utils/snack.dart';
import '../services/battery_optimization.dart';
import '../widgets/user_avatar.dart';
import 'blocked_users_screen.dart';

/// The signed-in user's profile: avatar, username, display name, primary
/// email, member-since date, editing (username / display name / avatar) and
/// app theme. Sign-out lives here too.
///
/// Avatar upload goes through Clerk (which hosts the image) and is mirrored
/// to the backend so other clients see it. It needs `dart:io` `File`, so it
/// is skipped on web (mirroring the auth screens' platform split).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;

  /// True once this screen has popped itself after sign-out, so a rebuild
  /// doesn't schedule a second pop.
  bool _poppedForSignOut = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(clerkAuthProvider);
    final auth = snapshot?.auth;
    final user = ref.watch(currentUserProvider);

    if (auth == null || !auth.isSignedIn || user == null) {
      // Sign-out (from this button, the session expiring, or elsewhere)
      // flips the root route to the sign-in screen — this profile is a
      // pushed route on top of it, so drop it instead of parking the user
      // on a forever-spinner.
      if (snapshot != null && !_poppedForSignOut) {
        _poppedForSignOut = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final email = auth.user?.email;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: UserAvatar(user: user, radius: 44),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => _changePhoto(auth),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Change photo'),
                ),
                if (user.profileImageUrl != null &&
                    user.profileImageUrl!.isNotEmpty)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _removePhoto(auth),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Center(
            child: Text(
              user.displayName,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          Center(
            child: Text(
              '@${user.username}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(height: 24),
          _InfoRow(
            icon: Icons.email_outlined,
            label: 'Email',
            value: email ?? '—',
          ),
          if (auth.user?.createdAt != null)
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              label: 'Member since',
              value: formatDate(auth.user!.createdAt),
            ),
          const SizedBox(height: 8),
          _EditButton(
            icon: Icons.badge_outlined,
            label: 'Edit username',
            onPressed: _busy ? null : () => _editUsername(auth, user),
          ),
          _EditButton(
            icon: Icons.person_outline,
            label: 'Edit display name',
            onPressed: _busy ? null : () => _editDisplayName(auth, user),
          ),
          const SizedBox(height: 24),
          Text('Theme', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _ThemePicker(),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked Users'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
            ),
          ),
          if (Platform.isAndroid)
            _BatteryTile(onChanged: () => setState(() {})),
          const Divider(),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _signOut(auth),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  /// Signs out, then pops this pushed route so the auth gate's sign-in
  /// screen is actually revealed (without this, the profile sits on top of
  /// it showing a spinner and sign-out looks like it never happened).
  Future<void> _signOut(ClerkAuthState auth) async {
    if (_busy) return;
    setState(() => _busy = true);
    debugPrint('[Profile] Signing out… (${auth.user?.email ?? auth.user?.username ?? 'unknown'})');
    try {
      // Completes even if the network call fails (the SDK flips the local
      // state to signed-out either way).
      await auth.signOut();
      debugPrint('[Profile] Signed out successfully');
    } on Exception catch (e) {
      debugPrint('[Profile] Sign out failed: $e');
      if (mounted) {
        showSnack(context, 'Sign out failed: $e');
      }
    } finally {
      // Navigate to the sign-in screen once the request finishes, whether it
      // succeeded or failed (the SDK flips to signed-out either way, so the
      // AuthGate root swaps to sign-in once this route is popped).
      if (mounted) {
        _poppedForSignOut = true;
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editUsername(ClerkAuthState auth, ChatUser user) async {
    final value = await promptText(
      context,
      title: 'Edit username',
      labelText: 'Username',
      initial: user.username,
      confirmLabel: 'Save',
      submitOnEnter: true,
    );
    if (value == null || !mounted) return;
    await _save(
      auth,
      () => ref.read(userRepositoryProvider).updateProfile(username: value),
      (updated) => auth.updateUser(username: updated.username),
    );
  }

  Future<void> _editDisplayName(ClerkAuthState auth, ChatUser user) async {
    final value = await promptText(
      context,
      title: 'Edit display name',
      labelText: 'Display name',
      initial: user.firstName ?? '',
      confirmLabel: 'Save',
      submitOnEnter: true,
    );
    if (value == null || !mounted) return;
    final name = value.trim();
    if (name.isEmpty) return;
    await _save(
      auth,
      () => ref.read(userRepositoryProvider).updateProfile(firstName: name),
      (updated) => auth.updateUser(firstName: updated.firstName),
    );
  }

  /// Picks an image from the gallery and sets it as the avatar via Clerk
  /// (which hosts the image), then mirrors the new URL to the backend so
  /// other clients see it.
  Future<void> _changePhoto(ClerkAuthState auth) async {
    final picked = await pickImage();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final temp = await Directory.systemTemp.createTemp('avatar');
      try {
        final file = File('${temp.path}/${picked.name}');
        await file.writeAsBytes(picked.bytes, flush: true);
        await auth.updateUserImage(file);
      } finally {
        try {
          await temp.delete(recursive: true);
        } on Exception {
          // Best-effort cleanup; the system temp dir is self-cleaning.
        }
      }
      final url = auth.user?.imageUrl;
      if (url != null && url.isNotEmpty) {
        await ref
            .read(userRepositoryProvider)
            .updateProfile(profileImageUrl: url);
      }
      if (mounted) {
        showSnack(context, 'Profile photo updated');
      }
    } on ApiException catch (e) {
      if (mounted) {
        showSnack(context, e.message);
      }
    } on Exception catch (e) {
      if (mounted) {
        showSnack(context, 'Failed to update photo: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removes the avatar in Clerk and clears it in the backend.
  Future<void> _removePhoto(ClerkAuthState auth) async {
    setState(() => _busy = true);
    try {
      await auth.deleteUserImage();
      await ref.read(userRepositoryProvider).updateProfile(profileImageUrl: '');
      if (mounted) {
        showSnack(context, 'Profile photo removed');
      }
    } on ApiException catch (e) {
      if (mounted) {
        showSnack(context, e.message);
      }
    } on Exception catch (e) {
      if (mounted) {
        showSnack(context, 'Failed to remove photo: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs the backend update, then mirrors it into the local Clerk state.
  Future<void> _save(
    ClerkAuthState auth,
    Future<ChatUser> Function() backend,
    Future<void> Function(ChatUser) mirror,
  ) async {
    setState(() => _busy = true);
    try {
      final updated = await backend();
      try {
        await mirror(updated);
      } on Exception {
        // Backend already saved; a Clerk-sync failure is non-fatal.
      }
      if (mounted) {
        showSnack(context, 'Profile updated');
      }
    } on ApiException catch (e) {
      if (mounted) {
        showSnack(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label, style: theme.textTheme.bodySmall),
      subtitle: Text(value, style: theme.textTheme.bodyLarge),
    );
  }
}

class _EditButton extends StatelessWidget {
  const _EditButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: onPressed,
    );
  }
}

/// Light / Dark / System mode selector + accent color swatches, driven by
/// the persisted [appThemeProvider].
class _ThemePicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appThemeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode),
              label: Text('Dark'),
            ),
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto),
              label: Text('System'),
            ),
          ],
          selected: {theme.mode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) =>
              ref.read(appThemeProvider.notifier).setMode(selection.first),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final seed in AppColorSeed.values) ...[
              Tooltip(
                message: seed.label,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () =>
                      ref.read(appThemeProvider.notifier).setSeed(seed),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: seed.color,
                      shape: BoxShape.circle,
                      border: theme.seed == seed
                          ? Border.all(color: scheme.onSurface, width: 3)
                          : null,
                    ),
                    child: theme.seed == seed
                        ? Icon(Icons.check,
                            color: seed.color.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                            size: 20)
                        : null,
                  ),
                ),
              ),
              if (seed != AppColorSeed.values.last)
                const SizedBox(width: 10),
            ],
          ],
        ),
      ],
    );
  }
}

/// Android-only row showing the battery-optimization exemption state, with
/// a tap-to-request action. Swiped-away apps without the exemption receive
/// no FCM notifications on many OEM phones.
class _BatteryTile extends StatefulWidget {
  const _BatteryTile({required this.onChanged});

  /// Called after the state may have changed so the parent rebuilds.
  final VoidCallback onChanged;

  @override
  State<_BatteryTile> createState() => _BatteryTileState();
}

class _BatteryTileState extends State<_BatteryTile> {
  bool? _exempted;

  @override
  void initState() {
    super.initState();
    isIgnoringBatteryOptimizations().then((v) {
      if (mounted) setState(() => _exempted = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final exempted = _exempted;
    final theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.battery_saver),
      title: const Text('Battery optimization'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            exempted == null
                ? 'Checking…'
                : exempted
                    ? 'Unrestricted — messages arrive even when closed'
                    : 'Restricted — swipe-away may block messages',
          ),
          if (exempted == false)
            FutureBuilder<String?>(
              future: deviceManufacturer(),
              builder: (_, snap) => snap.hasData
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        manufacturerHint(snap.data),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      trailing: exempted == true
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : const Icon(Icons.chevron_right),
      onTap: exempted == true
          ? null
          : () async {
              await requestIgnoreBatteryOptimizations();
              // Give the system dialog a moment; then refresh state.
              await Future<void>.delayed(const Duration(seconds: 2));
              final now = await isIgnoringBatteryOptimizations();
              if (!context.mounted) return;
              showSnack(
                context,
                now
                    ? 'Background activity allowed'
                    : 'Not allowed — notifications may not arrive when closed',
              );
              if (now) widget.onChanged();
              setState(() => _exempted = now);
            },
    );
  }
}
