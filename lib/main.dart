import 'dart:async';
import 'dart:io';

import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'cache/chat_cache.dart';
import 'core/app_navigator.dart';
import 'core/auth_bootstrap.dart';
import 'core/config.dart';
import 'providers/chat_list_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/auth_gate.dart';
import 'services/push_wiring.dart';

/// Entry point. Wraps the app in a guarded zone so stray asynchronous
/// errors (e.g. Hive's internal lock-failure completer when a second app
/// instance is running) are logged instead of killing the app.
void main() {
  runZonedGuarded(
    _main,
    (error, stackTrace) {
      // The Clerk SDK's internal session-token polling on web uses
      // BrowserClient, which throws ClientException (converted to
      // SocketException by ClerkProxyHttpService) when the relay is
      // unreachable. These are retried by the SDK and don't affect
      // the app — suppress the noisy zone-level logging.
      if (error is SocketException) return;
      debugPrint('Unhandled async error: $error\n$stackTrace');
    },
  );
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.clerkPublishableKey.isEmpty) {
    throw StateError(
      'Missing Clerk publishable key. Run with:\n'
      '  flutter run --dart-define=CLERK_PUBLISHABLE_KEY=pk_test_...\n'
      'Get the key from the Clerk dashboard (the same instance that serves '
      'chat-demo). It must have the Native platform enabled.',
    );
  }
  await Hive.initFlutter();
  final cache = await ChatCache.open();
  final prefs = await ThemePrefs.open();
  // No-op until Firebase is configured (then initializes the SDK).
  await initializeFirebaseIfAvailable();

  // Render the first frame BEFORE the Clerk bootstrap runs — it makes live
  // network calls with retries, and blocking `runApp` behind them left a
  // blank white launch screen whenever the relay was slow (e.g. tapping a
  // push notification on a cold start). [clerkAuthStateProvider] drives the
  // splash → app / splash → retry transition instead.
  runApp(ProviderScope(
    overrides: [
      chatCacheProvider.overrideWithValue(cache),
      themePrefsProvider.overrideWithValue(prefs),
    ],
    child: const ChatApp(),
  ));
}

/// Clerk bootstrap, off the critical path. Completes with null when
/// [createClerkAuthStateWithFallback] exhausts its retry window (relay down);
/// [BootstrapGate] then offers a Retry instead of hanging.
final clerkAuthStateProvider = FutureProvider<ClerkAuthState?>((ref) {
  return createClerkAuthStateWithFallback();
});

class ChatApp extends ConsumerWidget {
  const ChatApp({super.key});

  /// Global navigator — lets push-notification taps open a chat from any
  /// app state (see services/push_wiring.dart).
  static final GlobalKey<NavigatorState> navigatorKey = appNavigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appThemeProvider);

    // Splash/retry gate while the Clerk auth state is being created; once
    // ready, ClerkAuth wraps MaterialApp exactly as before so every route
    // can access the auth state from context.
    final authAsync = ref.watch(clerkAuthStateProvider);
    if (authAsync.isLoading || !authAsync.hasValue) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: theme.seed.color),
          useMaterial3: true,
        ),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final authState = authAsync.value;
    if (authState == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: theme.seed.color),
          useMaterial3: true,
        ),
        home: const BootstrapErrorScreen(),
      );
    }

    return ClerkAuth(
      authState: authState,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Chat App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: theme.seed.color),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: theme.seed.color,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: theme.mode,
        home: const AuthGate(),
      ),
    );
  }
}

/// Shown when the Clerk bootstrap gave up (backend/relay unreachable past
/// its retry window). Offers an explicit retry rather than wedging.
class BootstrapErrorScreen extends ConsumerWidget {
  const BootstrapErrorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            const Text("Couldn't reach the server"),
            const SizedBox(height: 8),
            const Text(
              'Check your connection and try again.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => ref.invalidate(clerkAuthStateProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
