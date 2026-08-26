import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../models/dictionary.dart';
import '../providers/dictionary_provider.dart';
import '../utils/snack.dart';
import '../utils/dialogs.dart';
import '../widgets/chat/dictionary_unlock_sheet.dart';

/// Per-chat code-word dictionary: list / add / edit / delete entries and
/// save them (re-encrypted client-side under the shared chat key or, for
/// passphrase-locked chats, under the key derived from the lock
/// passphrase). Also shows which members are still missing (or stale)
/// their key wrap.
class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key, required this.chat});

  final ChatSummary chat;

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  late List<DictEntry> _entries;
  bool _saving = false;

  /// Lock passphrase typed when CREATING a new dictionary (mandatory) —
  /// every dictionary is passphrase-locked from birth.
  final TextEditingController _passController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _entries = [...ref.read(dictionaryProvider(widget.chat.id)).entries];
  }

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final result =
        await ref.read(dictionaryProvider(widget.chat.id).notifier).save(
              [for (final e in _entries) if (e.isValid) e],
              lockPassphrase: _passController.text.trim(),
            );
    setState(() {
      _saving = false;
      if (result.ok && result.entries != null) {
        _entries = result.entries!;
      }
    });
    if (!mounted) return;
    showSnack(
      context,
      result.ok
          ? 'Dictionary saved'
          : result.error ?? 'Error',
    );
  }

  /// Prompts for a passphrase with an obscured field. Returns null on cancel.
  Future<String?> _promptPassphrase(
    BuildContext context, {
    required String title,
    required String label,
  }) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  /// Opts the (legacy, wrap-based) dictionary into the passphrase lock:
  /// re-encrypts under a derived key and drops the wraps.
  Future<void> _addLock() async {
    final passphrase = await _promptPassphrase(
      context,
      title: 'Add lock passphrase',
      label: 'Passphrase',
    );
    if (passphrase == null || passphrase.isEmpty) return;
    setState(() => _saving = true);
    final result =
        await ref.read(dictionaryProvider(widget.chat.id).notifier).addLock(
              passphrase,
            );
    if (!mounted) return;
    setState(() => _saving = false);
    showSnack(
      context,
      result.ok ? 'Dictionary locked' : result.error ?? 'Error',
    );
  }

  Future<void> _resetDictionary() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Start over?',
      message: 'The old dictionary can no longer be decrypted by any '
          'device. Starting over creates a new key and saves the current '
          'list (${_entries.where((e) => e.isValid).length} code words) for '
          'everyone.',
      confirmLabel: 'Start over',
      destructive: true,
    );
    if (!mounted || !confirmed) return;
    setState(() => _saving = true);
    final result =
        await ref.read(dictionaryProvider(widget.chat.id).notifier).reset(
              [for (final e in _entries) if (e.isValid) e],
            );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.ok && result.entries != null) {
        _entries = result.entries!;
      }
    });
    showSnack(
      context,
      result.ok ? 'Dictionary re-keyed' : result.error ?? 'Error',
    );
  }

  Future<void> _editEntry({int? index}) async {
    final isNew = index == null;
    final current = isNew ? const DictEntry(code: '', meaning: '') : _entries[index];
    final code = (await promptText(
      context,
      title: isNew ? 'New code word' : 'Edit code word',
      labelText: 'Code',
      hintText: 'e.g. m',
      initial: current.code,
      confirmLabel: 'OK',
    ))?.trim();
    if (code == null) return;
    if (!mounted) return;
    final meaning = (await promptText(
      context,
      title: isNew ? 'New code word' : 'Edit meaning',
      labelText: 'Meaning',
      hintText: 'e.g. Mark',
      initial: current.meaning,
      confirmLabel: 'OK',
    ))?.trim();
    if (meaning == null) return;
    setState(() {
      final entry = DictEntry(code: code, meaning: meaning);
      if (isNew) {
        // Codes must be unique per chat.
        if (_entries.any((e) => e.code == code)) {
          showSnack(context, 'Duplicate code');
          return;
        }
        _entries = [..._entries, entry];
      } else {
        _entries = [
          for (var i = 0; i < _entries.length; i++)
            i == index ? entry : _entries[i],
        ];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dict = ref.watch(dictionaryProvider(widget.chat.id));

    // Locked and not unlocked in this session: no editor at all. The room
    // usually gates navigation here, but this guard covers deep links.
    if (dict.isLocked) {
      return Scaffold(
        appBar: AppBar(title: Text('Code words · ${widget.chat.displayName}')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 40,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 12),
                Text(
                  'The code words are locked.\nEnter the shared passphrase '
                  'to view or edit them.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => showDictionaryUnlockSheet(
                    context,
                    chatId: widget.chat.id,
                  ),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: const Text('Unlock'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final creating = !dict.hasDictionary && !dict.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: Text('Code words · ${widget.chat.displayName}'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save dictionary',
              onPressed: _save,
            ),
            // Legacy (wrap-based) dictionaries can opt into the passphrase
            // lock; locked ones are already locked by definition.
            if (dict.hasDictionary && !dict.needsRekey)
              PopupMenuButton<String>(
                tooltip: 'More',
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'add-lock',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.lock_outline),
                      title: Text('Add lock passphrase'),
                    ),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'add-lock') _addLock();
                },
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (dict.error != null && !dict.isLoading)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      dict.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () => ref
                        .read(dictionaryProvider(widget.chat.id).notifier)
                        .reload(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          if (dict.needsRekey)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your device can’t read this dictionary anymore — the key '
                    'that encrypted it is lost. You can start over with a new '
                    'key (old code words can’t be recovered).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _saving ? null : _resetDictionary,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Start over'),
                  ),
                ],
              ),
            ),
          if (dict.isLoading && !dict.hasDictionary)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (creating) ...[
              Container(
                width: double.infinity,
                color: theme.colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Set a lock passphrase — every dictionary is locked. '
                      'Meanings stay hidden in the chat until a member '
                      'enters it (again after each app start). Share it '
                      'with members directly; new joiners need it too.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Lock passphrase',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_entries.isEmpty)
              const Expanded(
                child:
                    Center(child: Text('No code words yet — add one below.')),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return ListTile(
                      leading: const Icon(Icons.tag),
                      title: Text(entry.code),
                      subtitle: Text(entry.meaning),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _editEntry(index: index),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => setState(() {
                              _entries = [
                                for (var i = 0; i < _entries.length; i++)
                                  if (i != index) _entries[i],
                              ];
                            }),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
          const Divider(height: 1),
          _MemberWrapStatus(participants: dict.participants, wraps: dict.wraps),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Tip: stack codes with + — “m+h” reveals as “Mark home”.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : () => _editEntry(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add code word'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom strip: one line per member showing whether their wrap is current.
class _MemberWrapStatus extends StatelessWidget {
  const _MemberWrapStatus({required this.participants, required this.wraps});

  final List<DictionaryMember> participants;
  final Map<String, DictionaryWrap> wraps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (participants.isEmpty) return const SizedBox.shrink();

    // Group device entries by member so each person shows as one row.
    final byUser = <String, List<DictionaryMember>>{};
    for (final p in participants) {
      byUser.putIfAbsent(p.userId, () => []).add(p);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Who can open it',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 4),
          for (final entry in byUser.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      entry.value.first.username.isNotEmpty
                          ? entry.value.first.username[0]
                          : '?',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.value.first.username,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  _wrapBadge(context, entry.value),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Wrapped when every registered device of this member has a current wrap.
  Widget _wrapBadge(BuildContext context, List<DictionaryMember> devices) {
    final theme = Theme.of(context);
    final keyed = devices.where((d) => d.hasPublicKey).toList();
    if (keyed.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.help_outline, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 4),
          Text('no key yet', style: theme.textTheme.labelSmall),
        ],
      );
    }
    final current =
        keyed.where((d) => _wrapped(d)).length;
    if (current == keyed.length) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text('wrapped', style: theme.textTheme.labelSmall),
        ],
      );
    }
    final partial = keyed.length > 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
        const SizedBox(width: 4),
        Text(
          partial ? '$current/${keyed.length} devices' : 'needs re-key',
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }

  bool _wrapped(DictionaryMember member) {
    if (!member.hasPublicKey) return false;
    final wrap = wraps[member.key];
    if (wrap == null) return false;
    return wrap.deviceKeyVersion == member.encPublicKeyVersion;
  }
}