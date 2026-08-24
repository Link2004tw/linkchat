import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/deep_link.dart';

void main() {
  group('inviteCodeFromUri', () {
    test('extracts the code from a web-style https://host/join/<code> link', () {
      expect(
        inviteCodeFromUri(Uri.parse('https://chat.example.com/join/ABC123')),
        'ABC123',
      );
    });

    test('extracts the code from a native chatapp://join/<code> link', () {
      expect(inviteCodeFromUri(Uri.parse('chatapp://join/ABC123')), 'ABC123');
    });

    test('returns null for non-join links', () {
      expect(inviteCodeFromUri(Uri.parse('https://chat.example.com/room/c1')),
          isNull);
      expect(inviteCodeFromUri(Uri.parse('chatapp://open/ABC123')), isNull);
    });

    test('returns null for join links without a code', () {
      expect(inviteCodeFromUri(Uri.parse('https://chat.example.com/join')),
          isNull);
      expect(inviteCodeFromUri(Uri.parse('chatapp://join')), isNull);
    });

    test('returns null for null or empty input', () {
      expect(inviteCodeFromUri(null), isNull);
    });
  });
}