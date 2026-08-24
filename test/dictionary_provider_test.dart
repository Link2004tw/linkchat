import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/cache/chat_cache.dart';
import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/dictionary.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/providers/auth_providers.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/providers/dictionary_provider.dart';
import 'package:chat_app/providers/repository_providers.dart';
import 'package:chat_app/repositories/dictionary_repository.dart';
import 'package:chat_app/screens/dictionary_screen.dart';
import 'package:chat_app/services/dictionary_crypto.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

/// Simulates the backend's dictionary endpoints. Holds the current stored
/// version + encrypted blob (opaque server-side), decryptable only because
/// the test also holds the chat key.
class _FakeDictionaryServer {
  _FakeDictionaryServer({
    required this.crypto,
    required this.chatKey,
    required this.myPub,
    required this.myUserId,
    required this.myClerkId,
  });

  final DictionaryCrypto crypto;
  List<int> chatKey;
  final String myPub;
  final String myUserId;
  final String myClerkId;

  int version = 2;
  List<DictEntry> entries = [
    const DictEntry(code: 'a', meaning: 'Alpha'),
    const DictEntry(code: 'm', meaning: 'Mark'),
  ];

  /// Version of my registered device key (as the server sees it).
  int participantKeyVersion = 1;

  /// `deviceKeyVersion` baked into my wrap — lower than
  /// [participantKeyVersion] simulates another device re-registering.
  int wrapDeviceKeyVersion = 1;

  int putCalls = 0;
  bool failFirstPut = true;
  bool alwaysConflict = false;

  /// Optional interceptor (tests can short-circuit any request).
  http.Response? Function(http.Request req)? beforeRequest;

  Future<http.Response> handle(http.Request req) async {
    final intercepted = beforeRequest?.call(req);
    if (intercepted != null) return intercepted;
    final path = req.url.path;
    if (req.method == 'GET' && path == '/api/user/public-key') {
      return _json({'encPublicKey': myPub, 'version': participantKeyVersion});
    }
    if (req.method == 'POST' && path == '/api/user/public-key') {
      return _json({'version': 1});
    }
    if (req.method == 'GET' && path == '/api/chats/c1/dictionary') {
      return _json(await _contextJson());
    }
    if (req.method == 'PUT' && path == '/api/chats/c1/dictionary') {
      putCalls++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final dict = body['dictionary'] as Map<String, dynamic>;
      final payloadVersion = (dict['version'] as num).toInt();

      if (alwaysConflict) {
        version = payloadVersion;
        return _json(
          {'error': 'dictionary.version must be newer than the stored one'},
          409,
        );
      }
      if (failFirstPut && putCalls == 1) {
        // A concurrent save won in the meantime: stored version bumps past
        // the payload and new remote entries appear.
        failFirstPut = false;
        version = payloadVersion;
        entries = [
          const DictEntry(code: 'a', meaning: 'Alpha'),
          const DictEntry(code: 'b', meaning: 'Bravo'),
          const DictEntry(code: 'm', meaning: 'Mark'),
        ];
        return _json(
          {'error': 'dictionary.version must be newer than the stored one'},
          409,
        );
      }
      if (payloadVersion <= version) {
        return _json(
          {'error': 'dictionary.version must be newer than the stored one'},
          409,
        );
      }
      version = payloadVersion;
      entries = await crypto.decryptEntries(
        ciphertext: dict['ciphertext'] as String,
        iv: dict['iv'] as String,
        authTag: dict['authTag'] as String,
        chatKey: chatKey,
      );
      return _json({'version': payloadVersion});
    }
    return _json({'error': 'not found'}, 404);
  }

  Future<Map<String, dynamic>> _contextJson() async {
    final blob = await crypto.encryptEntries(entries: entries, chatKey: chatKey);
    final wrap = await crypto.wrapChatKey(
      chatKey: chatKey,
      memberUserId: myUserId,
      deviceKeyVersion: wrapDeviceKeyVersion,
      memberPubBase64: myPub,
    );
    return {
      'dictionary': {
        'ciphertext': blob.ciphertext,
        'iv': blob.iv,
        'authTag': blob.authTag,
        'version': version,
        'wraps': [wrap.toJson()],
      },
      'participants': [
        {
          'userId': myUserId,
          'clerkId': myClerkId,
          'username': 'me',
          'encPublicKey': myPub,
          'encPublicKeyVersion': participantKeyVersion,
        },
      ],
    };
  }
}

/// Avoids touching `flutter_secure_storage` (not available in tests) while
/// keeping the real X25519/AES-GCM crypto for the round trip. Chat-key
/// caching uses an in-memory map so self-heal paths are testable.
class _NoStorageCrypto extends DictionaryCrypto {
  _NoStorageCrypto(this.pair);

  final SimpleKeyPair pair;
  final Map<String, String> keyCache = {};

  @override
  Future<SimpleKeyPair> ensureKeyPair() async => pair;

  @override
  Future<void> cacheChatKey(String chatId, List<int> chatKey) async {
    keyCache[chatId] = base64Encode(chatKey);
  }

  @override
  Future<Uint8List?> getCachedChatKey(String chatId) async {
    final stored = keyCache[chatId];
    return stored == null ? null : base64Decode(stored);
  }

  @override
  Future<void> clearCachedChatKey(String chatId) async {
    keyCache.remove(chatId);
  }
}

Future<(Uint8List chatKey, String myPub, SimpleKeyPair pair)> _keyMaterial() async {
  final pair = await X25519().newKeyPair();
  final myPub = base64Encode((await pair.extractPublicKey()).bytes);
  final chatKey = Uint8List.fromList(await DictionaryCrypto().createChatKey());
  return (chatKey, myPub, pair);
}

Future<(ProviderContainer, _FakeDictionaryServer)> _make(
  (Uint8List, String, SimpleKeyPair) key,
  _FakeDictionaryServer? server,
) async {
  final (chatKey, myPub, pair) = key;
  final crypto = DictionaryCrypto();
  final fake = server ??
      _FakeDictionaryServer(
        crypto: crypto,
        chatKey: chatKey,
        myPub: myPub,
        myUserId: 'user_me',
        myClerkId: 'user_me',
      );
  final api = ApiClient(
    getToken: () async => 'test-jwt',
    httpClient: MockClient(fake.handle),
  );
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWithValue(
        const ChatUser(clerkId: 'user_me', username: 'me'),
      ),
      chatCacheProvider.overrideWithValue(ChatCache.memory),
      dictionaryCryptoProvider.overrideWithValue(_NoStorageCrypto(pair)),
      dictionaryRepositoryProvider.overrideWithValue(DictionaryRepository(api)),
    ],
  );
  addTearDown(container.dispose);
  return (container, fake);
}

Future<DictionaryController> _loadedController(
  ProviderContainer container,
) async {
  final controller = container.read(dictionaryProvider('c1').notifier);
  await controller.reload();
  return controller;
}

void main() {
  group('DictionaryController.save conflict recovery', () {
    test('merges remote edits onto local and retries after a 409', () async {
      final key = await _keyMaterial();
      final (container, fake) = await _make(key, null);
      final controller = await _loadedController(container);

      // Fresh server state was version 2 with [a, m].
      expect(controller.state.version, 2);
      expect(controller.state.entries.map((e) => e.code), ['a', 'm']);

      final result = await controller.save([
        const DictEntry(code: 'm', meaning: 'Markus'),
        const DictEntry(code: 'z', meaning: 'Zulu'),
      ]);

      expect(result.ok, isTrue, reason: result.error);
      // First PUT (version 3) lost to a concurrent save; the retry (version 4)
      // won. Both members' entries survive.
      expect(fake.putCalls, 2);
      expect(fake.version, 4);
      expect(result.entries!.map((e) => e.code), ['m', 'z', 'a', 'b']);
      expect(
        result.entries!.firstWhere((e) => e.code == 'm').meaning,
        'Markus',
      );
      expect(controller.state.version, 4);
      expect(controller.state.entries.map((e) => e.code), ['m', 'z', 'a', 'b']);
    });

    test('a non-conflict error surfaces as a failure', () async {
      final key = await _keyMaterial();
      final server = _FakeDictionaryServer(
        crypto: DictionaryCrypto(),
        chatKey: key.$1,
        myPub: key.$2,
        myUserId: 'user_me',
        myClerkId: 'user_me',
      )..alwaysConflict = true;
      final (container, _) = await _make(key, server);
      final controller = await _loadedController(container);

      final result = await controller.save([const DictEntry(code: 'm', meaning: 'Markus')]);
      expect(result.ok, isFalse);
      expect(result.error, contains('too many times'));
    });

    test('bails out when the device can no longer read after a reload', () async {
      final key = await _keyMaterial();
      final server = _FakeDictionaryServer(
        crypto: DictionaryCrypto(),
        chatKey: key.$1,
        myPub: key.$2,
        myUserId: 'user_me',
        myClerkId: 'user_me',
      );
      final (container, _) = await _make(key, server);
      final controller = await _loadedController(container);

      // After the 409, the reloaded context has no wrap for us → needsRekey.
      server.beforeRequest = (req) {
        if (req.method == 'GET' && req.url.path == '/api/chats/c1/dictionary') {
          return _json({
            'dictionary': {
              'ciphertext': 'ct',
              'iv': 'iv',
              'authTag': 'tag',
              'version': 3,
              'wraps': <Object>[],
            },
            'participants': [
              {
                'userId': 'user_me',
                'clerkId': 'user_me',
                'username': 'me',
                'encPublicKey': key.$2,
                'encPublicKeyVersion': 1,
              },
            ],
          });
        }
        return null;
      };

      final result = await controller.save([const DictEntry(code: 'm', meaning: 'Markus')]);
      expect(result.ok, isFalse);
      expect(result.error, contains('re-keyed'));
    });
  });

  group('DictionaryController self-healing rekey', () {
    test('a stale wrap recovers automatically from the cached chat key',
        () async {
      final key = await _keyMaterial();
      final (container, fake) = await _make(key, null);
      final controller = await _loadedController(container);
      expect(controller.state.needsRekey, isFalse);

      // Another of this user's devices re-registered: the server-side key
      // version bumps to 2, so our stored wrap (deviceKeyVersion 1) is
      // stale and a plain unwrap would fail.
      fake
        ..participantKeyVersion = 2
        ..failFirstPut = false;
      await controller.reload();

      // Self-heal: decrypted with the cached chat key, fresh wraps saved.
      expect(fake.putCalls, 1, reason: 'self-heal should PUT fresh wraps');
      expect(controller.state.needsRekey, isFalse);
      expect(controller.state.version, 3);
      expect(controller.state.entries.map((e) => e.code), ['a', 'm']);
      expect(controller.state.wraps['user_me']!.deviceKeyVersion, 2);
    });

    test('without a cached key it falls back to needsRekey', () async {
      final key = await _keyMaterial();
      final (container, fake) = await _make(key, null);
      final controller = await _loadedController(container);

      // Simulate never having opened it on this device install.
      (container.read(dictionaryCryptoProvider) as _NoStorageCrypto)
          .keyCache
          .clear();
      fake.participantKeyVersion = 2;
      await controller.reload();

      expect(fake.putCalls, 0, reason: 'nothing to self-heal with');
      expect(controller.state.needsRekey, isTrue);
      expect(controller.state.error, contains('unreadable'));
    });

    test('a stale cached key is dropped instead of being trusted', () async {
      final key = await _keyMaterial();
      final (container, fake) = await _make(key, null);
      final controller = await _loadedController(container);

      // Another member rotated the dictionary under a new chat key (they
      // still had it), and our wrap went stale at the same time.
      fake
        ..chatKey = Uint8List.fromList(await DictionaryCrypto().createChatKey())
        ..participantKeyVersion = 2;
      await controller.reload();

      expect(fake.putCalls, 0);
      expect(controller.state.needsRekey, isTrue);
      // The bad cached key was cleared so it can't be reused.
      expect(
        (container.read(dictionaryCryptoProvider) as _NoStorageCrypto)
            .keyCache
            .containsKey('c1'),
        isFalse,
      );
    });
  });

  group('DictionaryScreen', () {
    testWidgets('auto-merges a concurrent save and shows the merged list',
        (tester) async {
      final key = await _keyMaterial();
      final (chatKey, myPub, pair) = key;
      final crypto = DictionaryCrypto();
      final fake = _FakeDictionaryServer(
        crypto: crypto,
        chatKey: chatKey,
        myPub: myPub,
        myUserId: 'user_me',
        myClerkId: 'user_me',
      );
      final api = ApiClient(
        getToken: () async => 'test-jwt',
        httpClient: MockClient(fake.handle),
      );
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(
            const ChatUser(clerkId: 'user_me', username: 'me'),
          ),
          chatCacheProvider.overrideWithValue(ChatCache.memory),
          dictionaryCryptoProvider.overrideWithValue(_NoStorageCrypto(pair)),
          dictionaryRepositoryProvider.overrideWithValue(
            DictionaryRepository(api),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DictionaryScreen(
              chat: ChatSummary(id: 'c1', access: 'public', name: 'Test'),
            ),
          ),
        ),
      );
      // Wait for the provider's initial load to finish before editing.
      await _pumpUntil(
        tester,
        () => !container.read(dictionaryProvider('c1')).isLoading,
      );

      // Add z → Zulu.
      await tester.tap(find.text('Add code word'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'z');
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Zulu');
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();

      // Save — first PUT conflicts, auto-merge retries and succeeds.
      await tester.tap(find.byIcon(Icons.save_outlined));
      await tester.pump();
      await _pumpUntil(tester, () => fake.version == 4);
      await _pumpUntil(
        tester,
        () => find.text('Dictionary saved').evaluate().isNotEmpty,
      );

      // Merged list: local [z→Zulu] + remote-only [a, b, m].
      expect(find.text('Zulu'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Mark'), findsOneWidget);
    });
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready,
) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: 'timed out waiting for condition');
}