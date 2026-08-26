import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat.dart';
import '../../models/user.dart';
import '../../providers/auth_providers.dart';
import '../../providers/chat_list_provider.dart';
import '../../providers/friends_providers.dart';
import '../../providers/repository_providers.dart';
import '../../screens/chat_room_screen.dart';
import '../../screens/profile_screen.dart';
import '../../utils/dialogs.dart';
import '../../utils/snack.dart';
import '../user_avatar.dart';

/// Handles a tap on any user's avatar: your own → the full profile screen,
/// someone else → their profile bottom sheet. No-op when [clerkId] is null.
Future<void> openUserFromAvatar(
  BuildContext context,
  WidgetRef ref, {
  required String? clerkId,
  ChatUser? user,
}) async {
  if (clerkId == null || clerkId.isEmpty) return;
  final me = ref.read(currentUserProvider)?.clerkId;
  if (me != null && clerkId == me) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
    );
    return;
  }
  await showUserProfileSheet(context, ref, clerkId: clerkId, fallbackUser: user);
}

/// Opens the other-user profile bottom sheet for [clerkId].
///
/// [fallbackUser] seeds the header (name/avatar) while `GET /user/:clerkId`
/// is in flight, so taps on message-bubble avatars show something instantly.
Future<void> showUserProfileSheet(
  BuildContext context,
  WidgetRef ref, {
  required String clerkId,
  ChatUser? fallbackUser,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _UserProfileSheet(clerkId: clerkId, fallbackUser: fallbackUser),
  );
}

class _UserProfileSheet extends ConsumerStatefulWidget {
  const _UserProfileSheet({required this.clerkId, this.fallbackUser});

  final String clerkId;
  final ChatUser? fallbackUser;

  @override
  ConsumerState<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends ConsumerState<_UserProfileSheet> {
  UserSearchResult? _profile;
  bool _blockedByMe = false;
  bool _busy = false;
  String? _error;

  bool get _isSelf =>
      ref.read(currentUserProvider)?.clerkId == widget.clerkId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Your own avatar opens the full ProfileScreen via [openUserFromAvatar];
    // if the sheet is ever opened on self anyway, just render the fallback
    // header without any network calls.
    if (_isSelf) return;
    try {
      final profile =
          await ref.read(userRepositoryProvider).getUser(widget.clerkId);
      final blocked =
          await ref.read(userRepositoryProvider).getBlocked();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _blockedByMe = blocked.contains(widget.clerkId);
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────

  void _sendRequest() => _run(() async {
        await ref
            .read(friendsRepositoryProvider)
            .sendRequest(widget.clerkId);
        ref.invalidate(friendRequestsProvider);
      });

  void _cancelRequest(String requestId) => _run(() async {
        await ref.read(friendsRepositoryProvider).cancelRequest(requestId);
        ref.invalidate(friendRequestsProvider);
      });

  void _acceptRequest(String requestId) => _run(() async {
        await ref.read(friendsRepositoryProvider).acceptRequest(requestId);
        ref.invalidate(friendsProvider);
        ref.invalidate(friendRequestsProvider);
      });

  void _declineRequest(String requestId) => _run(() async {
        await ref.read(friendsRepositoryProvider).declineRequest(requestId);
        ref.invalidate(friendRequestsProvider);
      });

  Future<void> _removeFriend() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove friend?',
      message:
          'You will stay in shared rooms together, but they will no longer '
          'appear in your friends list.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed) return;
    await _run(() async {
      await ref.read(friendsRepositoryProvider).removeFriend(widget.clerkId);
      ref.invalidate(friendsProvider);
    });
  }

  Future<void> _toggleBlock() async {
    final blocking = !_blockedByMe;
    if (blocking) {
      final confirmed = await confirmDialog(
        context,
        title: 'Block user?',
        message:
            'They will not be able to DM you, send you friend requests, '
            'or invite you to rooms. Existing group rooms are unaffected.',
        confirmLabel: 'Block',
        destructive: true,
      );
      if (!confirmed) return;
    }
    await _run(() async {
      final repo = ref.read(userRepositoryProvider);
      if (blocking) {
        await repo.blockUser(widget.clerkId);
      } else {
        await repo.unblockUser(widget.clerkId);
      }
    });
  }

  /// Opens (or resolves + opens) the DM, then closes the sheet.
  Future<void> _openDm() async {
    final name = _profile?.user.displayName ?? '';
    final image = _profile?.user.profileImageUrl;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final resolved = _profile?.dmId ??
        await ref.read(friendsRepositoryProvider).getFriendDm(widget.clerkId);
    if (!mounted) return;
    Navigator.of(context).pop(); // loading dialog

    if (resolved == null) {
      showSnack(context, 'Could not open chat. Try again.');
      return;
    }

    ref.invalidate(chatListProvider);
    Navigator.of(context).pop(); // close the sheet
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatRoomScreen(
          chat: ChatSummary(
            id: resolved,
            access: 'direct',
            otherUser: ChatOtherUser(
              clerkId: widget.clerkId,
              name: name,
              imageUrl: image,
            ),
          ),
        ),
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;
    final headerUser = profile?.user ?? widget.fallbackUser;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (_error != null)
              Text('Profile unavailable', style: theme.textTheme.titleMedium)
            else if (profile == null && headerUser == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else ...[
              UserAvatar(user: headerUser!, radius: 44),
              const SizedBox(height: 12),
              Text(
                headerUser.displayName,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 2),
              Text(
                '@${headerUser.username}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if ((profile?.sharedRoomsCount ?? 0) > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${profile!.sharedRoomsCount} shared room${profile.sharedRoomsCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              ..._actions(profile),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(UserSearchResult? profile) {
    if (_isSelf || profile == null || _error != null) return const [];

    Widget button({required VoidCallback? onPressed, required Widget child}) =>
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: _busy ? null : onPressed,
            child: child,
          ),
        );

    switch (profile.friendRequestStatus) {
      case 'friends':
        return [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _openDm,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Message'),
            ),
          ),
          const SizedBox(height: 8),
          button(onPressed: _removeFriend, child: const Text('Remove friend')),
          const SizedBox(height: 8),
          button(
            onPressed: _toggleBlock,
            child: Text(_blockedByMe ? 'Unblock' : 'Block'),
          ),
        ];
      case 'pending':
        return [
          button(
            onPressed: () => _cancelRequest(profile.friendRequestId!),
            child: const Text('Cancel request'),
          ),
          const SizedBox(height: 8),
          button(onPressed: _toggleBlock, child: const Text('Block')),
        ];
      case 'respond':
        return [
          button(
            onPressed: () => _acceptRequest(profile.friendRequestId!),
            child: const Text('Accept'),
          ),
          const SizedBox(height: 8),
          button(
            onPressed: () => _declineRequest(profile.friendRequestId!),
            child: const Text('Decline'),
          ),
          const SizedBox(height: 8),
          button(onPressed: _toggleBlock, child: const Text('Block')),
        ];
      default:
        return [
          button(onPressed: _sendRequest, child: const Text('Add friend')),
          const SizedBox(height: 8),
          button(onPressed: _toggleBlock, child: const Text('Block')),
        ];
    }
  }
}
