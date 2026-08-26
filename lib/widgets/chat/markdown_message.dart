import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/markdown_util.dart';
import '../../models/user.dart';
import '../user_avatar.dart';
import 'link_launcher.dart';
import 'user_profile_sheet.dart';

/// Renders a text message body as markdown (headings, bold/italic,
/// strikethrough, code blocks, links). Bare URLs are wrapped by
/// [wrapBareUrls]; link taps open the browser. The style sheet is compact
/// so headings and code fit inside chat bubbles.
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({
    super.key,
    required this.text,
    required this.textColor,
    this.linkColor,
    this.mentionTokens = const [],
  });

  final String text;
  final Color textColor;

  /// Color for links and `@mention` tokens. Defaults to the theme's primary;
  /// own-message bubbles pass the on-primary color so links stay visible on
  /// the primary bubble background.
  final Color? linkColor;

  /// Mention tokens to render highlighted + tappable (see
  /// [mentionizeMarkdown]); taps open a member sheet instead of a browser.
  final List<MentionToken> mentionTokens;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(color: textColor);
    if (base == null) return const SizedBox.shrink();
    // Unset fields merge over the theme fallback inside the Markdown
    // widget, so only what we override is custom. Headings stay compact so
    // they don't dwarf the bubble.
    final sheet = MarkdownStyleSheet(
      p: base,
      h1: base.copyWith(
        fontSize: base.fontSize! * 1.35,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      h2: base.copyWith(
        fontSize: base.fontSize! * 1.2,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      h3: base.copyWith(
        fontSize: base.fontSize! * 1.1,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      h4: base.copyWith(fontWeight: FontWeight.w600),
      h5: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      strong: base.copyWith(fontWeight: FontWeight.w700),
      del: base.copyWith(decoration: TextDecoration.lineThrough),
      code: base.copyWith(
        fontFamily: 'monospace',
        fontSize: base.fontSize! * 0.9,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      a: base.copyWith(
        color: linkColor ?? theme.colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
      blockSpacing: 4,
      listIndent: 16,
    );
    // MarkdownBody (not Markdown): the scrolling variant needs bounded
    // height, which a chat bubble can't provide. Mentions are wrapped as
    // `#mention:` links first; bare URLs are then wrapped too (the
    // lookbehind skips already-markdown links, so no double-wrapping).
    return MarkdownBody(
      data: mentionizeMarkdown(wrapBareUrls(text), mentionTokens),
      styleSheet: sheet,
      // Preserve single newlines so multi-line messages keep their line
      // breaks instead of collapsing to spaces.
      softLineBreak: true,
      // The default extension set is GitHub-Flavored (strikethrough etc.).
      onTapLink: (_, href, _) => _handleLinkTap(context, href ?? ''),
    );
  }

  /// `#mention:<userId>` links open the member sheet; everything else opens
  /// the browser (the existing URL handling).
  void _handleLinkTap(BuildContext context, String href) {
    const prefix = '#mention:';
    if (href.startsWith(prefix)) {
      final id = href.substring(prefix.length);
      final token = mentionTokens
          .where((t) => t.userId == id)
          .firstOrNull;
      _showMentionSheet(context, token ?? MentionToken(name: '', userId: id));
      return;
    }
    openUrl(context, href);
  }
}

/// Bottom sheet for a tapped `@mention`: avatar + username (+ Clerk id),
/// or "Everyone in this room" for `@all`.
void _showMentionSheet(BuildContext context, MentionToken token) {
  final isAll = token.userId == 'all';
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => Consumer(
      builder: (ctx, sheetRef, _) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: isAll
            ? Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    child: const Icon(Icons.alternate_email, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@all',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                      Text(
                        'Everyone in this room',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              )
            : ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(
                  user: ChatUser(clerkId: token.userId, username: token.name),
                  radius: 18,
                ),
                title: Text(
                  '@${token.name}',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                subtitle: Text(token.userId),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openUserFromAvatar(
                  ctx,
                  sheetRef,
                  clerkId: token.userId,
                  user: ChatUser(clerkId: token.userId, username: token.name),
                ),
              ),
      ),
      ),
    ),
  );
}