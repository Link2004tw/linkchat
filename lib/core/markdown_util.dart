/// Markdown helpers for message bubbles.
///
/// Bare URLs are wrapped in markdown link syntax so they render as
/// clickable links, while content inside code fences is left untouched (a
/// URL in a code sample is code, not a link). URLs already written as
/// markdown links (`[text](url)`) are skipped via a lookbehind so they are
/// never double-wrapped. Any `scheme://` URL is matched — http(s) plus
/// custom schemes like the `chatapp://join/<code>` invite links.
String wrapBareUrls(String text) {
  if (!text.contains('://')) return text;
  final fenceRe = RegExp(r'^\s*(```|~~~)\s*$');
  final urlRe = RegExp(
    r'(?<![A-Za-z0-9+\-.(\[])'
    r'([a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"()\[\]]+)',
  );
  final trailingPunct = RegExp(r'[.,;:!?]+$');

  var inCode = false;
  final lines = text.split('\n');
  final out = <String>[];
  for (final line in lines) {
    if (fenceRe.hasMatch(line)) {
      inCode = !inCode;
      out.add(line);
      continue;
    }
    if (inCode) {
      out.add(line);
      continue;
    }
    if (!urlRe.hasMatch(line)) {
      out.add(line);
      continue;
    }
    out.add(line.replaceAllMapped(urlRe, (m) {
      var url = m[0]!;
      final trimmed = url.replaceAll(trailingPunct, '');
      // Sentence punctuation after the URL stays outside the link.
      final suffix = url.substring(trimmed.length);
      if (trimmed.isNotEmpty) url = trimmed;
      return '[$url]($url)$suffix';
    }));
  }
  return out.join('\n');
}

/// Mentions in message text — a `@username` or `@all` token that should
/// render highlighted and tappable.
class MentionToken {
  const MentionToken({required this.name, required this.userId});

  /// The `@`-less name as it appears in the text (used for matching).
  final String name;

  /// The resolved user id, or `'all'` for `@all`.
  final String userId;
}

/// Wraps mention tokens as markdown links so `MarkdownBody` renders them
/// highlighted (the link color) and tappable. The href is a private
/// `#mention:<userId>` scheme the bubble intercepts (see
/// `MarkdownMessage.onTapLink`) instead of opening a browser.
///
/// Matching is case-insensitive with word boundaries, and each token is
/// replaced by the *original* typed text so `@Bob` stays `@Bob`. Mentions
/// inside code fences are left untouched (a code sample mentioning a
/// username is code, not a mention).
String mentionizeMarkdown(
  String text,
  List<MentionToken> tokens,
) {
  if (tokens.isEmpty) return text;
  final fenceRe = RegExp(r'^\s*(```|~~~)\s*$');

  var inCode = false;
  final lines = text.split('\n');
  final out = <String>[];
  for (final line in lines) {
    if (fenceRe.hasMatch(line)) {
      inCode = !inCode;
      out.add(line);
      continue;
    }
    if (inCode) {
      out.add(line);
      continue;
    }
    var processed = line;
    for (final t in tokens) {
      final re = RegExp('@${RegExp.escape(t.name)}(?![A-Za-z0-9_])',
          caseSensitive: false);
      processed = processed.replaceAllMapped(re, (m) {
        // Escape underscores in the label so `[a_b](url)` can't be parsed
        // as emphasis; the label stays visually identical.
        final label = m[0]!.replaceAll('_', r'\_');
        return '[$label](#mention:${t.userId})';
      });
    }
    out.add(processed);
  }
  return out.join('\n');
}
