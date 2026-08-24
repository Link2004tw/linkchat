import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/api_client.dart';
import 'package:chat_app/core/config.dart';

void main() {
  test('Clerk publishable key defaults to a test key, never a live key', () {
    // The default is a shared Clerk *test* key (public by design) so plain
    // `flutter run` works without flags. Per-environment keys override it
    // via --dart-define=CLERK_PUBLISHABLE_KEY. Committing a live key here
    // would be a security bug, so assert the default is only ever a test key.
    expect(AppConfig.clerkPublishableKey, startsWith('pk_test_'));
  });

  test('API host defaults to the public ngrok backend over https/wss', () {
    // The backend + DB are co-located on the dev machine and exposed through
    // ngrok, so the default talks to that public URL from any device. Local
    // dev overrides it via --dart-define=API_HOST.
    expect(
      AppConfig.apiHost,
      'flirtatiously-chalcolithic-bria.ngrok-free.dev',
    );
    expect(AppConfig.useHttps, isTrue);
    expect(
      AppConfig.api('/chats/all'),
      'https://flirtatiously-chalcolithic-bria.ngrok-free.dev/api/chats/all',
    );
    expect(
      AppConfig.chatWsUrl(chatId: 'c1'),
      'wss://flirtatiously-chalcolithic-bria.ngrok-free.dev:443/ws/chat?chatId=c1',
    );
  });

  test('ApiClient rejects calls when no session token is available', () async {
    final client = ApiClient(getToken: () async => null);

    await expectLater(
      client.get('/chats/all'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
  });
}
