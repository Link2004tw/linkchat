import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../../models/chat.dart';
import '../../utils/format.dart';
import '../../utils/snack.dart';


/// Text input + attach + send.
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.onSend,
    required this.onTyping,
    this.onAttach,
    this.onVoiceSend,
    this.onEdit,
    this.editingMessageId,
    this.editingInitialText,
    this.onCancelEdit,
    this.participants = const [],
    this.myUserId,
    this.loadParticipants,
    this.canSend = true,
    this.lockedHint,
    this.lockedCtaLabel,
    this.onLockedCta,
  });

  final void Function(String text) onSend;
  final VoidCallback onTyping;

  /// Called with (messageId, newText) when the user submits an edit.
  final void Function(String messageId, String newText)? onEdit;

  /// Non-null when the bar is in edit mode: the id of the message being edited.
  final String? editingMessageId;

  /// The original text to pre-fill when entering edit mode.
  final String? editingInitialText;

  /// Exits edit mode without saving.
  final VoidCallback? onCancelEdit;

  /// Opens the media picker (photo/file). Hidden when null.
  final VoidCallback? onAttach;

  /// Sends a recorded voice note (bytes + suggested name + mime). Hidden
  /// when null; the mic is desktop/mobile-only (no recorder on web yet).
  final Future<void> Function(Uint8List bytes, String name, String mime)?
      onVoiceSend;

  /// Room members for the `@` mention picker.
  final List<RoomParticipant> participants;

  /// Fetches the room's members on demand (called on the first `@`
  /// keystroke when [participants] is still empty).
  final Future<List<RoomParticipant>> Function()? loadParticipants;

  /// The signed-in user's Clerk id (excluded from the picker — you can't
  /// mention yourself).
  final String? myUserId;

  /// False for admins-only rooms when the current user isn't an admin: the
  /// bar renders read-only (no text input, attach or mic).
  final bool canSend;

  /// Text shown in the read-only state; defaults to the admins-only hint.
  /// DMs pass a friend-removal-aware message.
  final String? lockedHint;

  /// Label for the call-to-action button shown next to [lockedHint] when
  /// sending is blocked (e.g. "Add as friend" on a non-friend DM).
  final String? lockedCtaLabel;

  /// Invoked when the locked-state CTA is tapped; providing it renders the
  /// input row disabled in place (instead of replacing it with the read-only
  /// hint) plus the hint strip with the CTA. The button disables itself for
  /// the duration of the returned future (no double-fires).
  final Future<void> Function()? onLockedCta;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      // Ctrl+Enter (or Cmd+Enter on macOS) sends the message.
      // Plain Enter inserts a newline (thanks to TextInputAction.newline).
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
        final isMod = HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        if (isMod) {
          _submit();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };
  }
  bool _recording = false;
  Duration _elapsed = Duration.zero;
  String? _recordingPath;

  /// Members matching the in-flight `@query` (empty → picker hidden).
  List<RoomParticipant> _mentionCandidates = [];

  /// True when the `@all` option should appear (group chats only).
  bool _showMentionAll = false;

  /// Offset (in chars) where the `@query` starts — the picker replaces the
  /// text from here to the caret when a candidate is chosen.
  int _mentionStart = -1;

  /// Guards against firing the on-demand member fetch more than once while
  /// it's still in flight.
  bool _loadingParticipants = false;

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Entering edit mode: pre-fill the text field.
    if (widget.editingMessageId != null &&
        oldWidget.editingMessageId == null &&
        widget.editingInitialText != null) {
      _controller.text = widget.editingInitialText!;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    }
    // Exiting edit mode: clear the text field.
    if (widget.editingMessageId == null && oldWidget.editingMessageId != null) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isEditing => widget.editingMessageId != null;

  /// Locked with a CTA (e.g. a non-friend DM): the input row stays visible
  /// but disabled, next to the hint strip.
  bool get _lockedWithCta => !widget.canSend && widget.onLockedCta != null;

  void _submit() {
    if (!widget.canSend) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (_isEditing) {
      widget.onEdit?.call(widget.editingMessageId!, text);
      widget.onCancelEdit?.call();
    } else {
      widget.onSend(text);
    }
    _controller.clear();
    _hideMentions();
  }

  /// Updates the mention picker state from the text up to the caret.
  void _updateMentions(String text, int caret) {
    final upToCaret = text.substring(0, caret.clamp(0, text.length));
    final at = upToCaret.lastIndexOf('@');
    // A mention starts at a word boundary: `@` at the start or after a
    // space — `foo@bob` and `@bobbery` (mid-word) are not mentions.
    if (at < 0 ||
        (at > 0 && upToCaret[at - 1] != ' ' && upToCaret[at - 1] != '\n')) {
      _hideMentions();
      return;
    }
    final query = upToCaret.substring(at + 1);
    if (query.contains(' ') || query.contains('\n')) {
      _hideMentions();
      return;
    }
    final q = query.toLowerCase();
    final others = widget.participants
        .where((p) => p.clerkId != widget.myUserId)
        .toList();
    setState(() {
      _mentionStart = at;
      _mentionCandidates = others
          .where((p) => p.username.toLowerCase().startsWith(q))
          .toList();
      // `@all` only makes sense with 2+ other members.
      _showMentionAll = others.length >= 2 && 'all'.startsWith(q);
    });
    // The member list may not be loaded yet — fetch it once and re-run the
    // filter with the fresh participants.
    if (widget.participants.isEmpty &&
        widget.loadParticipants != null &&
        !_loadingParticipants) {
      _loadingParticipants = true;
      widget.loadParticipants!().then((loaded) {
        _loadingParticipants = false;
        if (!mounted || loaded.isEmpty) return;
        _updateMentions(_controller.text, _controller.selection.baseOffset);
      }).catchError((_) {
        _loadingParticipants = false;
      });
    }
  }

  void _hideMentions() {
    if (_mentionCandidates.isEmpty && !_showMentionAll) return;
    setState(() {
      _mentionCandidates = [];
      _showMentionAll = false;
      _mentionStart = -1;
    });
  }

  /// Replaces the in-flight `@query` with `@name ` and hides the picker.
  void _insertMention(String name) {
    final text = _controller.text;
    final caret = _controller.selection.baseOffset;
    final start = _mentionStart < 0 ? caret : _mentionStart;
    final before = text.substring(0, start);
    final after = text.substring(caret.clamp(0, text.length));
    _controller.value = TextEditingValue(
      text: '$before@$name $after',
      selection: TextSelection.collapsed(offset: before.length + name.length + 2),
    );
    _hideMentions();
    widget.onTyping();
  }

  Future<void> _startRecording() async {
    if (!widget.canSend) return;
    if (kIsWeb) return;
    final ok = await _recorder.hasPermission();
    if (!ok) {
      if (mounted) {
        showSnack(context, 'Microphone permission denied');
      }
      return;
    }
    final path =
        '${Directory.systemTemp.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 22050,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Could not start recording');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recordingPath = path;
      _elapsed = Duration.zero;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  /// Stops recording; sends the bytes when [send] is true, otherwise
  /// discards the temp file.
  Future<void> _stopRecording({required bool send}) async {
    _timer?.cancel();
    final stoppedPath = await _recorder.stop();
    if (mounted) setState(() => _recording = false);
    final path = stoppedPath ?? _recordingPath;
    _recordingPath = null;
    if (!send || path == null) {
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      return;
    }
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final bytes = await f.readAsBytes();
      await widget.onVoiceSend?.call(
        bytes,
        'voice_${DateTime.now().millisecondsSinceEpoch}.wav',
        'audio/wav',
      );
      try {
        await f.delete();
      } catch (_) {}
    } catch (_) {
      // Recording/read failure — the send callback surfaced errors already.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mentionCandidates.isNotEmpty || _showMentionAll)
              _MentionSuggestions(
                candidates: _mentionCandidates,
                showAll: _showMentionAll,
                onPick: _insertMention,
              ),
            _recording
            ? Row(
                children: [
                  const Icon(Icons.graphic_eq, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Text(
                    formatDuration(_elapsed),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Discard recording',
                    onPressed: () => _stopRecording(send: false),
                  ),
                  IconButton.filled(
                    icon: const Icon(Icons.stop),
                    tooltip: 'Send voice note',
                    onPressed: () => _stopRecording(send: true),
                  ),
                ],
              )
            : widget.canSend
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isEditing)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(8),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.edit_outlined,
                                size: 16,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Editing message',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Cancel edit',
                                onPressed: widget.onCancelEdit,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        ),
                      _buildInputRow(theme),
                    ],
                  )
                : _lockedWithCta
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildInputRow(theme),
                          const SizedBox(height: 6),
                          _LockedStrip(
                            hint: widget.lockedHint,
                            ctaLabel: widget.lockedCtaLabel,
                            onCta: widget.onLockedCta,
                          ),
                        ],
                      )
                    : _ReadOnlyHint(text: widget.lockedHint),
          ],
        ),
      ),
    );
  }

  /// The attach/mic/text-field/send row. Rendered enabled for open rooms and
  /// disabled in place when locked with a CTA (non-friend DMs).
  Widget _buildInputRow(ThemeData theme) {
    final onAttach = widget.onAttach;
    final showMic = widget.onVoiceSend != null && !kIsWeb;
    return Row(
      children: [
        if (!_isEditing && onAttach != null) ...[
          IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined),
            tooltip: 'Attach photo or file',
            onPressed: widget.canSend ? onAttach : null,
          ),
          const SizedBox(width: 4),
        ],
        if (!_isEditing && showMic) ...[
          IconButton(
            icon: const Icon(Icons.mic_outlined),
            tooltip: 'Record voice note',
            onPressed: widget.canSend ? _startRecording : null,
          ),
          const SizedBox(width: 4),
        ],
        if (_isEditing)
          const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            textInputAction: TextInputAction.newline,
            minLines: 1,
            maxLines: 4,
            enabled: widget.canSend,
            decoration: InputDecoration(
              hintText: _isEditing ? 'Edit message' : 'Message',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) {
              widget.onTyping();
              _updateMentions(value, _controller.selection.baseOffset);
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          onPressed: widget.canSend ? _submit : null,
          icon: Icon(_isEditing ? Icons.check : Icons.send),
          tooltip: _isEditing ? 'Save edit' : 'Send',
        ),
      ],
    );
  }
}

/// The `@`-mention suggestion strip: matching members + `@all` (group).
class _MentionSuggestions extends StatelessWidget {
  const _MentionSuggestions({
    required this.candidates,
    required this.showAll,
    required this.onPick,
  });

  final List<RoomParticipant> candidates;
  final bool showAll;
  final void Function(String username) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <Widget>[
      if (showAll)
        _MentionChip(
          label: '@all',
          subtitle: 'Everyone in this room',
          onTap: () => onPick('all'),
        ),
      for (final p in candidates)
        _MentionChip(
          label: '@${p.username}',
          subtitle: p.role,
          onTap: () => onPick(p.username),
        ),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 160),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: items,
        ),
      ),
    );
  }
}

class _MentionChip extends StatelessWidget {
  const _MentionChip({
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.alternate_email, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );

  }
}

/// Shown in place of the input row when the room is read-only for the
/// current user (admins-only rooms, or a DM disabled after a friend removal).
class _ReadOnlyHint extends StatelessWidget {
  const _ReadOnlyHint({this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text ?? 'Only admins can send in this room',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hint strip below a disabled-in-place input row; optionally carries the
/// locked-state call-to-action (e.g. "Add as friend" on non-friend DMs).
class _LockedStrip extends StatefulWidget {
  const _LockedStrip({this.hint, this.ctaLabel, this.onCta});

  final String? hint;
  final String? ctaLabel;
  final Future<void> Function()? onCta;

  @override
  State<_LockedStrip> createState() => _LockedStripState();
}

class _LockedStripState extends State<_LockedStrip> {
  /// True while the CTA's future is in flight: the button is disabled so a
  /// double-tap can't fire the request twice.
  bool _busy = false;

  Future<void> _handleTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onCta?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.hint ?? 'Only admins can send in this room',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (widget.onCta != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : _handleTap,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.ctaLabel ?? 'Add as friend'),
            ),
          ],
        ],
      ),
    );
  }
}
