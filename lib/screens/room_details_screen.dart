import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/deep_link.dart';
import 'join_invite_screen.dart';

import '../models/chat.dart';
import '../models/user.dart';
import '../models/ws_event.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_list_provider.dart';
import '../providers/chat_room_provider.dart';
import '../providers/repository_providers.dart';
import '../utils/media_picker.dart';
import '../utils/snack.dart';
import '../widgets/user_avatar.dart';
import '../widgets/chat/user_profile_sheet.dart';
import 'invite_screen.dart';
import '../widgets/error_state.dart';
import '../utils/dialogs.dart';

/// Room details: info block, the participant list merged with live online
/// dots, admin controls (rename / access / can-send / invite) and leave.
/// Direct chats get a minimal other-user card. Replaces MembersScreen.
class RoomDetailsScreen extends ConsumerStatefulWidget {
  const RoomDetailsScreen({super.key, required this.chat, this.onRenamed});

  final ChatSummary chat;

  /// Called after a successful rename so the room screen's AppBar can show
  /// the new name without reopening the room.
  final void Function(String name)? onRenamed;

  @override
  ConsumerState<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

class _RoomDetailsScreenState extends ConsumerState<RoomDetailsScreen> {
  RoomInfo? _info;
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  /// Whether I've blocked the DM partner (null = still loading). DMs only.
  bool? _dmBlockedByMe;

  ChatSummary get chat => widget.chat;

  bool get _isDm => chat.isDm;

  @override
  void initState() {
    super.initState();
    if (!_isDm) {
      _load();
    } else {
      _loadDmBlockState();
    }
  }

  /// Spec §14: the DM header offers block/unblock. Loads the current state
  /// so the action renders the right label.
  Future<void> _loadDmBlockState() async {
    final otherId = chat.otherUser?.clerkId;
    if (otherId == null) return;
    try {
      final blocked = await ref
          .read(userRepositoryProvider)
          .getBlocked()
          .then((set) => set.contains(otherId));
      if (mounted) setState(() => _dmBlockedByMe = blocked);
    } on Exception {
      // Leave null → action stays hidden; blocking is optional UX.
    }
  }

  Future<void> _toggleBlockDmPartner() async {
    final otherId = chat.otherUser?.clerkId;
    if (otherId == null || _dmBlockedByMe == null) return;
    final blocking = !_dmBlockedByMe!;
    final repo = ref.read(userRepositoryProvider);

    if (blocking) {
      final confirmed = await confirmDialog(
        context,
        title: 'Block ${chat.displayName}?',
        message:
            'They will not be able to DM you, send you friend requests, '
            'or invite you to rooms. Existing group rooms are unaffected.',
        confirmLabel: 'Block',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _busy.add('block'));
    try {
      if (blocking) {
        await repo.blockUser(otherId);
      } else {
        await repo.unblockUser(otherId);
      }
      if (!mounted) return;
      setState(() => _dmBlockedByMe = blocking);
      showSnack(context, blocking ? 'User blocked' : 'User unblocked');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Could not update block: $e');
    } finally {
      if (mounted) setState(() => _busy.remove('block'));
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await ref.read(chatsRepositoryProvider).getInfo(chat.id);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Best-effort REST refresh of the chat list after an admin change, so
  /// the new name shows on the Chats tab immediately even if the live
  /// `room-update` WS event is missed. Failures are fine — the WS event
  /// (or the next pull-to-refresh) covers the list too.
  Future<void> _refreshChatList() async {
    // `ref` is unusable once the widget is disposed; `ref.read` then throws
    // a StateError (an Error, not an Exception) — catch-all is intentional
    // for this fire-and-forget refresh.
    if (!mounted) return;
    try {
      await ref.read(chatListProvider.notifier).refresh();
    } catch (_) {
      // Best-effort only.
    }
  }

  /// Refetches room info when another client changes name / access / can-send /
  /// roles / members, so an open details screen stays current without reopening.
  void _handleListEvent(ChatListEvent event) {
    if (_isDm || _loading) return;
    final relevant = switch (event) {
      ChatListRoomUpdateEvent(:final chatId) => chatId == chat.id,
      ChatListMembershipEvent(:final chatId, :final type) =>
        chatId == chat.id &&
            (type == 'invited' || type == 'kicked' || type == 'leave-chat'),
      _ => false,
    };
    if (relevant) _load();
  }

  // ── Admin actions ────────────────────────────────────────────────────

  Future<void> _rename() async {
    final name = (await promptText(
      context,
      title: 'Rename room',
      hintText: 'Room name',
      initial: _info?.name ?? '',
      maxLength: 50,
      confirmLabel: 'Rename',
      validate: (v) => v.trim().isNotEmpty && v.trim().length <= 50,
    ))?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final newName = await ref
          .read(chatsRepositoryProvider)
          .rename(chat.id, name);
      if (!mounted) return;
      widget.onRenamed?.call(newName);
      await _load();
      // `_load` awaits the network — the screen may have been disposed
      // while it was in flight; stop before touching ref/context.
      if (!mounted) return;
      unawaited(_refreshChatList());
      showSnack(context, 'Room renamed');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Rename failed: $e');
    }
  }

  /// Admin "Edit description" action: a multiline dialog that sets the
  /// room's free-text description (empty clears it).
  Future<void> _editDescription() async {
    final description = await promptText(
      context,
      title: 'Room description',
      hintText: 'What is this room about?',
      initial: _info?.description ?? '',
      maxLines: 3,
      minLines: 2,
      maxLength: 300,
      textCapitalization: TextCapitalization.sentences,
      confirmLabel: 'Save',
    ).then((v) => v?.trim());
    if (description == null || !mounted) return;
    try {
      await ref
          .read(chatsRepositoryProvider)
          .updateDescription(chat.id, description);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      unawaited(_refreshChatList());
      showSnack(context, 'Room description saved');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Could not save description: $e');
    }
  }

  /// Admin "Room photo" action: pick + upload a new picture, or remove the
  /// current one (empty URL clears it server-side).
  Future<void> _changePhoto() async {
    final hasPhoto = _info?.pictureUrl?.isNotEmpty ?? false;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () => Navigator.of(ctx).pop('choose'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove photo'),
              enabled: hasPhoto,
              onTap: () => Navigator.of(ctx).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'remove') {
      await _setPicture('');
      return;
    }

    final picked = await pickImage();
    if (picked == null || !mounted) return;
    try {
      final url = await ref
          .read(chatsRepositoryProvider)
          .uploadImageBytes(picked.bytes, picked.name);
      await _setPicture(url);
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Photo upload failed: $e');
    }
  }

  Future<void> _setPicture(String url) async {
    setState(() => _busy.add('picture'));
    try {
      await ref.read(chatsRepositoryProvider).updatePicture(chat.id, url);
      if (!mounted) return;
      await _load();
      unawaited(_refreshChatList());
      if (!mounted) return;
      showSnack(
        context,
        url.isEmpty ? 'Room photo removed' : 'Room photo updated',
      );
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove('picture'));
    }
  }

  Future<void> _changeAccess() async {
    final current = _info?.access ?? 'public';
    final access = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Room access'),
        children: [
          for (final option in const ['public', 'protected', 'private'])
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(option),
              child: Row(
                children: [
                  if (option == current) const Icon(Icons.check, size: 18),
                  const SizedBox(width: 8),
                  Text(option),
                ],
              ),
            ),
        ],
      ),
    );
    if (access == null || access == current || !mounted) return;
    try {
      await ref.read(chatsRepositoryProvider).updateAccess(chat.id, access);
      await _load();
      if (!mounted) return;
      showSnack(context, 'Access updated');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Update failed: $e');
    }
  }

  Future<void> _toggleSendPolicy() async {
    final info = _info;
    if (info == null) return;
    final next = info.canSendMessages == 'everyone' ? 'admins' : 'everyone';
    try {
      await ref
          .read(chatsRepositoryProvider)
          .updateCanSendMessage(chat.id, next);
      await _load();
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Update failed: $e');
    }
  }

  Future<void> _invite() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => InviteScreen(chatId: chat.id)),
    );
    // New members may have joined — refresh the list.
    await _load();
  }

  /// Admin "Invite link" sheet: shows the shareable link with Copy
  /// (Clipboard), Share (`share_plus`), Generate new and Revoke. A fresh
  /// link is fetched on open because the server owns the URL format
  /// (`INVITE_LINK_BASE` → `https://<base>/join/<code>`, else the
  /// `chatapp://join/<code>` fallback).
  Future<void> _inviteLinkSheet() async {
    final repo = ref.read(chatsRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    InviteLink link;
    try {
      link = await repo.createInviteLink(chat.id);
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Could not generate invite link: $e');
      return;
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Invite link',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _info?.name ?? chat.displayName,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () {
                      final code = inviteCodeFromUri(Uri.parse(link.url));
                      Navigator.of(ctx).pop();
                      if (code != null && context.mounted) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => JoinInviteScreen(initialCode: code),
                          ),
                        );
                      } else {
                        launchUrl(
                          Uri.parse(link.url),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        link.url,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Or share the code: ${link.code}',
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: link.url),
                          );
                          showSnackVia(messenger, 'Invite link copied');
                        },
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Share'),
                        onPressed: () {
                          final url = link.url;
                          final title =
                              'Join ${_info?.name ?? chat.displayName}';
                          Navigator.of(ctx).pop();
                          unawaited(
                            SharePlus.instance.share(
                              ShareParams(text: url, title: title),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () async {
                      try {
                        final fresh = await repo.createInviteLink(chat.id);
                        setSheetState(() => link = fresh);
                      } on Exception catch (e) {
                        showSnackVia(messenger, 'Could not regenerate: $e');
                      }
                    },
                    child: const Text('Generate new link'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () async {
                      try {
                        await repo.revokeInviteLink(chat.id);
                        if (!ctx.mounted) return;
                        Navigator.of(ctx).pop();
                        await _load();
                        if (mounted) showSnack(context, 'Invite link revoked');
                      } on Exception catch (e) {
                        showSnackVia(messenger, 'Could not revoke: $e');
                      }
                    },
                    child: const Text('Revoke link'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // The sheet may have regenerated the link — reflect it in the tile.
    await _load();
  }

  Future<void> _kick(RoomParticipant participant) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Kick @${participant.username}?',
      message:
          'They will be removed from the room and can only return if invited.',
      confirmLabel: 'Kick',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy.add(participant.clerkId));
    try {
      await ref
          .read(chatsRepositoryProvider)
          .kick(chat.id, participant.clerkId);
      await _load();
      if (!mounted) return;
      showSnack(context, '@${participant.username} was kicked');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Kick failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(participant.clerkId));
    }
  }

  Future<void> _setRole(RoomParticipant participant, String role) async {
    final makeAdmin = role == 'admin';
    final action = makeAdmin ? 'Make admin' : 'Remove admin';
    final confirmed = await confirmDialog(
      context,
      title: '$action @${participant.username}?',
      message: makeAdmin
          ? 'They will be able to manage the room like you.'
          : 'They will lose admin rights in this room.',
      confirmLabel: action,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy.add(participant.clerkId));
    try {
      await ref
          .read(chatsRepositoryProvider)
          .setRole(chat.id, participant.clerkId, role);
      await _load();
      if (!mounted) return;
      showSnack(
        context,
        makeAdmin
            ? '@${participant.username} is now an admin'
            : '@${participant.username} is no longer an admin',
      );
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Role update failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(participant.clerkId));
    }
  }

  Future<void> _mute(RoomParticipant participant) async {
    final duration = await showModalBottomSheet<String?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Mute for 8 hours'),
              onTap: () => Navigator.pop(ctx, '8h'),
            ),
            ListTile(
              title: const Text('Mute for 1 week'),
              onTap: () => Navigator.pop(ctx, '1w'),
            ),
            ListTile(
              title: const Text('Mute forever'),
              onTap: () => Navigator.pop(ctx, 'forever'),
            ),
            ListTile(
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx, null),
            ),
          ],
        ),
      ),
    );
    if (duration == null || !mounted) return;
    setState(() => _busy.add(participant.clerkId));
    try {
      await ref
          .read(chatsRepositoryProvider)
          .muteMember(chat.id, participant.clerkId, duration);
      await _load();
      if (!mounted) return;
      showSnack(context, '@${participant.username} was muted');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Mute failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(participant.clerkId));
    }
  }

  Future<void> _unmute(RoomParticipant participant) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Unmute @${participant.username}?',
      message: 'They will be able to send messages again.',
      confirmLabel: 'Unmute',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy.add(participant.clerkId));
    try {
      await ref
          .read(chatsRepositoryProvider)
          .unmuteMember(chat.id, participant.clerkId);
      await _load();
      if (!mounted) return;
      showSnack(context, '@${participant.username} was unmuted');
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Unmute failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(participant.clerkId));
    }
  }

  Future<void> _leave() async {
    final amOwner = _info?.myRelation == 'owner';
    final confirmed = await confirmDialog(
      context,
      title: 'Leave room?',
      message: amOwner
          ? 'You are the owner. Leaving transfers ownership to another member.'
          : 'You will no longer see this room.',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(chatsRepositoryProvider).leave(chat.id);
      if (!mounted) return;
      Navigator.of(context).pop(); // close details
      Navigator.of(context).pop(); // close the room
    } on Exception catch (e) {
      if (mounted) showSnack(context, 'Leave failed: $e');
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<ChatListEvent>>(chatListEventsProvider, (_, next) {
      next.whenData(_handleListEvent);
    });
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isDm ? chat.displayName : (info?.name ?? chat.displayName),
        ),
      ),
      body: _isDm
          ? _dmCard()
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorState()
          : info == null
          ? const Center(child: CircularProgressIndicator())
          : _groupView(info),
    );
  }

  Widget _dmCard() {
    final theme = Theme.of(context);
    final other = chat.otherUser;
    final user = ChatUser(
      clerkId: other?.clerkId,
      username: chat.displayName,
      profileImageUrl: other?.imageUrl,
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar(
            user: user,
            radius: 40,
            onTap: () => openUserFromAvatar(context, ref, clerkId: other?.clerkId, user: user),
          ),
          const SizedBox(height: 12),
          Text(chat.displayName, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Direct message',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          if (_dmBlockedByMe != null) ...[
            const SizedBox(height: 16),
            _dmBlockedByMe!
                ? OutlinedButton.icon(
                    onPressed: _busy.contains('block') ? null : _toggleBlockDmPartner,
                    icon: const Icon(Icons.lock_open_outlined),
                    label: const Text('Unblock user'),
                  )
                : OutlinedButton.icon(
                    onPressed: _busy.contains('block') ? null : _toggleBlockDmPartner,
                    icon: const Icon(Icons.block_outlined),
                    label: const Text('Block user'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
          ],
        ],
      ),
    );
  }

  Widget _errorState() {
    return ErrorState(message: _error!, onRetry: _load);
  }

  Widget _groupView(RoomInfo info) {
    final theme = Theme.of(context);
    final room = ref.watch(chatRoomProvider(chat.id));
    final me = ref.watch(currentUserProvider);
    final onlineCount = info.participants
        .where((p) => room.onlineUsers.containsKey(p.clerkId))
        .length;

    return ListView(
      children: [
        _infoBlock(info),
        const Divider(),
        if (info.isAdmin) ...[
          _sectionHeader('Admin'),
          ListTile(
            leading: const Icon(Icons.photo_outlined),
            title: const Text('Room photo'),
            subtitle: (info.pictureUrl?.isNotEmpty ?? false)
                ? const Text('Tap to change or remove')
                : null,
            onTap: _busy.contains('picture') ? null : _changePhoto,
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename room'),
            onTap: _rename,
          ),
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: const Text('Room description'),
            subtitle: (info.description.isNotEmpty)
                ? const Text('Tap to edit or clear')
                : const Text('Add a description for this room'),
            onTap: _editDescription,
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Change access'),
            onTap: _changeAccess,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Only admins can send'),
            value: info.canSendMessages == 'admins',
            onChanged: (_) => _toggleSendPolicy(),
          ),
          ListTile(
            leading: const Icon(Icons.person_add_alt_1_outlined),
            title: const Text('Invite people'),
            onTap: _invite,
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Invite link'),
            subtitle: (info.inviteCode == null)
                ? const Text('Generate a link to share this room')
                : const Text('Tap to copy or share the invite link'),
            onTap: _inviteLinkSheet,
          ),
          const Divider(),
        ],
        _sectionHeader(
          'Members (${info.participants.length})',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text('$onlineCount online', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
        for (final participant in info.participants)
          _participantTile(participant, room, me, theme),
        const Divider(),
        ListTile(
          leading: Icon(Icons.logout, color: theme.colorScheme.error),
          title: Text(
            'Leave room',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          onTap: _leave,
        ),
      ],
    );
  }

  /// Room picture with a fallback icon (group rooms only; direct chats never
  /// reach this header).
  Widget _roomAvatar(String? pictureUrl) {
    final theme = Theme.of(context);
    final hasPhoto = pictureUrl != null && pictureUrl.isNotEmpty;
    return CircleAvatar(
      radius: 24,
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundImage: hasPhoto ? NetworkImage(pictureUrl) : null,
      child: hasPhoto
          ? null
          : Icon(Icons.groups, color: theme.colorScheme.onPrimaryContainer),
    );
  }

  Widget _infoBlock(RoomInfo info) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _roomAvatar(info.pictureUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  info.name ?? chat.displayName,
                  style: theme.textTheme.headlineSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              _badge(info.access),
            ],
          ),
          const SizedBox(height: 12),
          if (info.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                info.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          _infoRow(
            'Who can send',
            info.canSendMessages == 'everyone' ? 'Everyone' : 'Admins only',
          ),
          if (info.createdBy != null)
            _infoRow('Created by', _creatorName(info, info.createdBy!)),
          _infoRow('Your role', info.myRelation ?? '—'),
        ],
      ),
    );
  }

  /// Resolves a creator Clerk ID to a username from the participant list.
  String _creatorName(RoomInfo info, String clerkId) {
    for (final p in info.participants) {
      if (p.clerkId == clerkId) return p.username;
    }
    return clerkId;
  }

  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _badge(String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }

  Widget _participantTile(
    RoomParticipant participant,
    ChatRoomState room,
    ChatUser? me,
    ThemeData theme,
  ) {
    final user = ChatUser(
      clerkId: participant.clerkId,
      username: participant.username,
      profileImageUrl: participant.profileImageUrl,
    );
    final isOnline = room.onlineUsers.containsKey(participant.clerkId);
    final canKick =
        (_info?.isAdmin ?? false) &&
        participant.clerkId != me?.clerkId &&
        participant.role != 'owner';
    final canManageRole =
        _info?.myRelation == 'owner' &&
        participant.clerkId != me?.clerkId &&
        participant.role != 'owner';
    final busy = _busy.contains(participant.clerkId);

    return ListTile(
      onTap: () => openUserFromAvatar(context, ref, clerkId: participant.clerkId, user: user),
      leading: UserAvatar(
        user: user,
        radius: 20,
        showStatusDot: true,
        isOnline: isOnline,
      ),
      title: Row(
        children: [
          Text(participant.username),
          if (participant.isMutedNow)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.volume_off, size: 16, color: Colors.grey),
            ),
        ],
      ),
      subtitle: Text(
        isOnline ? 'online' : 'offline',
        style: theme.textTheme.bodySmall?.copyWith(
          color: isOnline ? Colors.green : theme.colorScheme.outline,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _badge(participant.role),
          if (canManageRole) ...[
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: 'Manage member',
              icon: const Icon(Icons.more_vert),
              enabled: !busy,
              onSelected: (value) {
                if (value == 'kick') {
                  _kick(participant);
                } else if (value == 'mute') {
                  _mute(participant);
                } else if (value == 'unmute') {
                  _unmute(participant);
                } else {
                  _setRole(participant, value);
                }
              },
              itemBuilder: (_) => [
                if (participant.role == 'member' || participant.role == 'guest')
                  const PopupMenuItem(
                    value: 'admin',
                    child: Text('Make admin'),
                  ),
                if (participant.role == 'admin')
                  const PopupMenuItem(
                    value: 'member',
                    child: Text('Remove admin'),
                  ),
                if (participant.isMutedNow)
                  const PopupMenuItem(
                    value: 'unmute',
                    child: Text('Unmute'),
                  )
                else
                  const PopupMenuItem(
                    value: 'mute',
                    child: Text('Mute…'),
                  ),
                const PopupMenuItem(value: 'kick', child: Text('Kick')),
              ],
            ),
          ] else if (canKick) ...[
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.person_remove_outlined),
              tooltip: 'Kick',
              onPressed: busy ? null : () => _kick(participant),
            ),
          ],
        ],
      ),
    );
  }
}
