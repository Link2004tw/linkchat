import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/markdown_util.dart';

void main() {
  group('wrapBareUrls', () {
    test('wraps a bare URL in markdown link syntax', () {
      expect(
        wrapBareUrls('see https://example.com now'),
        'see [https://example.com](https://example.com) now',
      );
    });

    test('wraps a chatapp:// invite link', () {
      expect(
        wrapBareUrls('join at chatapp://join/ABC123'),
        'join at [chatapp://join/ABC123](chatapp://join/ABC123)',
      );
    });

    test('wraps any custom scheme:// URL', () {
      expect(
        wrapBareUrls('scheme ftp://files.example.com/a'),
        'scheme [ftp://files.example.com/a](ftp://files.example.com/a)',
      );
    });

    test('leaves code fences untouched', () {
      final input = '```\nhttps://example.com\n```';
      expect(wrapBareUrls(input), input);
    });

    test('does not double-wrap an existing markdown link', () {
      expect(
        wrapBareUrls('[x](https://example.com)'),
        '[x](https://example.com)',
      );
    });

    test('trims trailing punctuation from the URL', () {
      expect(
        wrapBareUrls('go https://example.com.'),
        'go [https://example.com](https://example.com).',
      );
    });

    test('no URL → unchanged', () {
      expect(wrapBareUrls('plain text'), 'plain text');
      expect(wrapBareUrls('a:// without a scheme is untouched'), 'a:// without a scheme is untouched');
    });

    test('multi-line: only URLs outside fences are wrapped', () {
      final input = 'see https://a.com\n```\nhttps://b.com\n```\nand https://c.com';
      final out = wrapBareUrls(input);
      expect(out, contains('[https://a.com](https://a.com)'));
      expect(out, contains('https://b.com')); // inside the fence, untouched
      expect(out, contains('[https://c.com](https://c.com)'));
    });
  });
}
