import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/cache/chat_cache.dart';
import 'package:chat_app/providers/theme_provider.dart';

void main() {
  ProviderContainer buildContainer([ThemePrefs? prefs]) {
    final container = ProviderContainer(
      overrides: [
        themePrefsProvider.overrideWithValue(prefs ?? ThemePrefs.memory),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AppThemeController', () {
    test('defaults to system mode + indigo seed', () {
      final theme = buildContainer().read(appThemeProvider);
      expect(theme.mode, ThemeMode.system);
      expect(theme.seed, AppColorSeed.indigo);
    });

    test('setMode and setSeed update state and persist', () async {
      final prefs = ThemePrefs.memory;
      final container = buildContainer(prefs);

      await container.read(appThemeProvider.notifier).setMode(ThemeMode.dark);
      await container.read(appThemeProvider.notifier).setSeed(AppColorSeed.teal);

      final theme = container.read(appThemeProvider);
      expect(theme.mode, ThemeMode.dark);
      expect(theme.seed, AppColorSeed.teal);
      expect(prefs.modeName, 'dark');
      expect(prefs.seedName, 'teal');
    });

    test('restores the saved choice on build', () async {
      final prefs = ThemePrefs.memory;
      await prefs.save(mode: ThemeMode.light, seed: AppColorSeed.purple);

      final theme = buildContainer(prefs).read(appThemeProvider);
      expect(theme.mode, ThemeMode.light);
      expect(theme.seed, AppColorSeed.purple);
    });

    test('falls back to defaults for unknown persisted values', () async {
      final store = MemoryCacheStore();
      await store.put('theme_mode', 'oops');
      await store.put('theme_seed', 'nope');

      final theme = buildContainer(ThemePrefs(store)).read(appThemeProvider);
      expect(theme.mode, ThemeMode.system);
      expect(theme.seed, AppColorSeed.indigo);
    });

    test('copyWith preserves the other field', () {
      const base = AppTheme(mode: ThemeMode.light, seed: AppColorSeed.indigo);
      final changed = base.copyWith(seed: AppColorSeed.blue);
      expect(changed.mode, ThemeMode.light);
      expect(changed.seed, AppColorSeed.blue);
    });
  });
}