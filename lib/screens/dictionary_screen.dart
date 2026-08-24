import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../models/dictionary.dart';
import '../providers/dictionary_provider.dart';
import '../utils/snack.dart';
import '../utils/dialogs.dart';

/// Per-chat code-word dictionary: list / add / edit / delete entries and
/// save them (re-encrypted client-side under the shared chat key). Also
/// shows which members are still missing (or stale) their key wrap.
class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key, required this.chat});

  final ChatSummary chat;

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  late List<DictEntry> _entries;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _entries = [...ref.read(dictionaryProvider(widget.chat.id)).entries];
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final result =
        await ref.read(dictionaryProvider(widget.chat.id).notifier).save(
              [for (final e in _entries) if (e.isValid) e],
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
      result.ok ? 'Dictionary saved' : result.error ?? 'Error',
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
          else
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save dictionary',
              onPressed: _save,
            ),
        ],
      ),
      body: Column(
        children: [
          if (dict.needsRekey)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                'Your device can’t read this dictionary yet — ask a member '
                'to open and save it so your key gets wrapped.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          if (dict.isLoading && !dict.hasDictionary)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_entries.isEmpty)
            const Expanded(
              child: Center(child: Text('No code words yet — add one below.')),
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