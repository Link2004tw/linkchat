import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/dictionary.dart';
import 'package:chat_app/services/dictionary_crypto.dart';

DictEntry _e(String code, String meaning) => DictEntry(code: code, meaning: meaning);

void main() {
  group('replaceOutgoing', () {
    final entries = [_e('m', 'Mark'), _e('hq', 'headquarters')];

    test('replaces whole real words with codes', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Meet Mark at 8', entries),
        'Meet m at 8',
      );
    });

    test('respects word boundaries (no partial matches)', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Marker and markings', entries),
        'Marker and markings',
      );
      expect(
        DictionaryCrypto.replaceOutgoing('at headquarters!', entries),
        'at hq!',
      );
    });

    test('leaves codes already present untouched', () {
      expect(
        DictionaryCrypto.replaceOutgoing('see m there', entries),
        'see m there',
      );
    });

    test('case-sensitive by default', () {
      expect(DictionaryCrypto.replaceOutgoing('MARK', entries), 'MARK');
    });

    test('empty dictionary is a no-op', () {
      expect(DictionaryCrypto.replaceOutgoing('Mark', const []), 'Mark');
    });

    test('punctuation boundaries are preserved', () {
      expect(
        DictionaryCrypto.replaceOutgoing('(Mark), Mark. Mark!', entries),
        '(m), m. m!',
      );
    });
  });

  group('replaceOutgoing auto-stacking', () {
    final entries = [_e('m', 'Mark'), _e('h', 'home'), _e('t', 'tomorrow')];

    test('consecutive dictionary words stack with +', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Mark home tomorrow', entries),
        'm+h+t',
      );
    });

    test('non-dictionary words break the run', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Mark is home', entries),
        'm is h',
      );
    });

    test('punctuation breaks the run', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Mark, home', entries),
        'm, h',
      );
      expect(
        DictionaryCrypto.replaceOutgoing('(Mark home)', entries),
        '(m+h)',
      );
    });

    test('trailing punctuation after a stack is preserved', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Mark home!', entries),
        'm+h!',
      );
    });

    test('a lone dictionary word is a single code (no +)', () {
      expect(
        DictionaryCrypto.replaceOutgoing('Meet Mark at 8', entries),
        'Meet m at 8',
      );
    });

    test('phrase meanings still replace as whole phrases', () {
      final phraseEntries = [
        _e('m2', 'Mark and Sarah'),
        _e('m', 'Mark'),
        _e('s', 'Sarah'),
      ];
      expect(
        DictionaryCrypto.replaceOutgoing(
          'Mark and Sarah coming',
          phraseEntries,
        ),
        'm2 coming',
      );
    });
  });

  group('expandIncoming', () {
    final entries = [_e('m', 'Mark'), _e('hq', 'headquarters')];

    test('expands all codes when no reveal subset given', () {
      expect(
        DictionaryCrypto.expandIncoming('go to hq with m', entries),
        'go to headquarters with Mark',
      );
    });

    test('expands only the codes in the reveal set', () {
      expect(
        DictionaryCrypto.expandIncoming('hq with m', entries, reveal: {'m'}),
        'hq with Mark',
      );
    });

    test('leaves unknown tokens alone', () {
      expect(
        DictionaryCrypto.expandIncoming('xx hq', entries),
        'xx headquarters',
      );
    });

    test('longer codes win over prefixes', () {
      final longEntries = [_e('m', 'Mark'), _e('mo', 'Momo')];
      expect(
        DictionaryCrypto.expandIncoming('mo and m', longEntries),
        'Momo and Mark',
      );
    });

    test('empty dictionary is a no-op', () {
      expect(DictionaryCrypto.expandIncoming('m', const []), 'm');
    });
  });

  group('expandIncoming stacks', () {
    final entries = [_e('m', 'Mark'), _e('h', 'home'), _e('t', 'tomorrow')];

    test('stack expands to space-joined meanings', () {
      expect(
        DictionaryCrypto.expandIncoming('m+h+t', entries),
        'Mark home tomorrow',
      );
    });

    test('stack mixed with plain text', () {
      final hq = [_e('m', 'Mark'), _e('hq', 'headquarters')];
      expect(
        DictionaryCrypto.expandIncoming('go to m+hq now', hq),
        'go to Mark headquarters now',
      );
    });

    test('longest code wins within a segment', () {
      final entries = [
        _e('m', 'Mark'),
        _e('h', 'home'),
        _e('q', 'quarters'),
        _e('hq', 'headquarters'),
      ];
      expect(
        DictionaryCrypto.expandIncoming('m+hq', entries),
        'Mark headquarters',
      );
    });

    test('unknown segments stay literal', () {
      expect(
        DictionaryCrypto.expandIncoming('m+zz', entries),
        'Mark zz',
      );
    });

    test('stacks inside punctuation', () {
      expect(
        DictionaryCrypto.expandIncoming('(m+h)', entries),
        '(Mark home)',
      );
    });

    test('reveal subset applies inside a stack', () {
      expect(
        DictionaryCrypto.expandIncoming('m+h', entries, reveal: {'m'}),
        'Mark h',
      );
    });

    test('space-separated codes still expand (backward compat)', () {
      expect(
        DictionaryCrypto.expandIncoming('m h', entries),
        'Mark home',
      );
    });

    test('spaced + stays literal', () {
      expect(
        DictionaryCrypto.expandIncoming('m + h', entries),
        'Mark + home',
      );
    });
  });

  group('round trip (real crypto)', () {
    test('wrap + unwrap restores the chat key', () async {
      final crypto = DictionaryCrypto();
      final chatKey = await crypto.createChatKey();
      final memberKeyPair = await X25519().newKeyPair();
      final memberPub = await memberKeyPair.extractPublicKey();
      final memberPubB64 = base64Encode(memberPub.bytes);

      final wrap = await crypto.wrapChatKey(
        chatKey: chatKey,
        memberUserId: 'user-1',
        deviceId: 'device-a',
        deviceKeyVersion: 3,
        memberPubBase64: memberPubB64,
      );
      expect(wrap.encKey, isNotEmpty);
      expect(wrap.wrapPub, isNotEmpty);

      final unwrapped = await crypto.unwrapChatKey(
        myKeyPair: memberKeyPair,
        wrap: wrap,
      );
      expect(List<int>.from(unwrapped), equals(List<int>.from(chatKey)));
    });

    test('encrypt + decrypt dictionary entries', () async {
      final crypto = DictionaryCrypto();
      final chatKey = await crypto.createChatKey();
      final entries = [_e('m', 'Mark'), _e('hq', 'headquarters')];

      final blob = await crypto.encryptEntries(entries: entries, chatKey: chatKey);
      final decrypted = await crypto.decryptEntries(
        ciphertext: blob.ciphertext,
        iv: blob.iv,
        authTag: blob.authTag,
        chatKey: chatKey,
      );
      expect(decrypted, hasLength(2));
      expect(decrypted.first.code, 'm');
      expect(decrypted.first.meaning, 'Mark');
      expect(decrypted.last.code, 'hq');
    });
  });

  group('DictEntry validation', () {
    test('isValid requires non-empty code and meaning', () {
      expect(const DictEntry(code: 'm', meaning: 'Mark').isValid, isTrue);
      expect(const DictEntry(code: '', meaning: 'Mark').isValid, isFalse);
      expect(const DictEntry(code: 'm', meaning: ' ').isValid, isFalse);
    });
  });

  group('mergeDictionaryEntries', () {
    final remote = [_e('a', 'Alpha'), _e('m', 'Mark'), _e('x', 'X-ray')];

    test('local entries win for duplicate codes', () {
      final local = [_e('m', 'Markus'), _e('z', 'Zulu')];
      final merged = DictionaryCrypto.mergeDictionaryEntries(remote: remote, local: local);
      expect(merged.map((e) => e.code), ['m', 'z', 'a', 'x']);
      expect(merged.firstWhere((e) => e.code == 'm').meaning, 'Markus');
    });

    test('remote-only entries are preserved', () {
      final local = [_e('z', 'Zulu')];
      final merged = DictionaryCrypto.mergeDictionaryEntries(remote: remote, local: local);
      expect(merged.map((e) => e.code), ['z', 'a', 'm', 'x']);
    });

    test('local ordering is kept, remote-only appended in order', () {
      final local = [_e('m', 'Markus'), _e('z', 'Zulu')];
      final merged = DictionaryCrypto.mergeDictionaryEntries(remote: remote, local: local);
      expect(merged, hasLength(4));
      expect(merged.first.code, 'm');
      expect(merged[1].code, 'z');
      expect(merged[2].code, 'a');
      expect(merged[3].code, 'x');
    });

    test('empty remote is a no-op passthrough', () {
      final local = [_e('z', 'Zulu')];
      final merged = DictionaryCrypto.mergeDictionaryEntries(remote: const [], local: local);
      expect(merged.map((e) => e.code), ['z']);
    });

    test('empty local keeps remote untouched', () {
      final merged = DictionaryCrypto.mergeDictionaryEntries(remote: remote, local: const []);
      expect(merged.map((e) => e.code), ['a', 'm', 'x']);
    });
  });
}
