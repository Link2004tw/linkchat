import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/chat_cache.dart';

/// Accent color choices. The seed drives the whole `ColorScheme` (via
/// `ColorScheme.fromSeed`) in both light and dark modes.
enum AppColorSeed {
  indigo('Indigo', Colors.indigo),
  blue('Blue', Colors.blue),
  teal('Teal', Colors.teal),
  purple('Purple', Colors.purple),
  deepOrange('Orange', Colors.deepOrange);

  const AppColorSeed(this.label, this.color);

  final String label;
  final Color color;
}

/// The app-wide theme choice: light/dark/system mode + an accent seed.
class AppTheme {
  const AppTheme({required this.mode, required this.seed});

  final ThemeMode mode;
  final AppColorSeed seed;

  static const AppTheme defaultTheme =
      AppTheme(mode: ThemeMode.system, seed: AppColorSeed.indigo);

  AppTheme copyWith({ThemeMode? mode, AppColorSeed? seed}) => AppTheme(
        mode: mode ?? this.mode,
        seed: seed ?? this.seed,
      );
}

/// Persistent theme preferences — a thin slice of Hive that mirrors
/// [ChatCache], so tests can substitute an in-memory store.
class ThemePrefs {
  ThemePrefs(this._store);

  static const String _modeKey = 'theme_mode';
  static const String _seedKey = 'theme_seed';
  static const String _batteryPromptKey = 'battery_prompt_dismissed';

  final CacheStore _store;

  /// Opens (or reopens) the Hive-backed prefs. Call once from `main()`
  /// after `Hive.initFlutter()`.
  ///
  /// Falls back to in-memory prefs when the Hive box can't be locked — e.g.
  /// another instance of the app already has it open — so a lock hiccup
  /// never takes the app down at startup.
  static Future<ThemePrefs> open() async {
    final box = await tryOpenHiveBox('chat_prefs');
    if (box == null) {
      debugPrint(
        'chat_prefs: could not lock Hive box (another instance running?) — '
        'using in-memory prefs',
      );
      return ThemePrefs.memory;
    }
    return ThemePrefs(HiveCacheStore(box));
  }

  /// An in-memory prefs used as the provider default in tests.
  static ThemePrefs get memory => ThemePrefs(MemoryCacheStore());

  String? get modeName => _store.get(_modeKey);

  String? get seedName => _store.get(_seedKey);

  Future<void> save({ThemeMode? mode, AppColorSeed? seed}) async {
    if (mode != null) await _store.put(_modeKey, mode.name);
    if (seed != null) await _store.put(_seedKey, seed.name);
  }

  /// True once the user dismissed the battery-optimization prompt ("Not
  /// now") — we never nag twice.
  bool get batteryPromptDismissed => _store.get(_batteryPromptKey) == 'true';

  Future<void> dismissBatteryPrompt() => _store.put(_batteryPromptKey, 'true');
}

final themePrefsProvider = Provider<ThemePrefs>((ref) => ThemePrefs.memory);

/// Current theme mode + accent. Restores the saved choice on app start and
/// persists any change through [themePrefsProvider].
class AppThemeController extends Notifier<AppTheme> {
  @override
  AppTheme build() {
    final prefs = ref.watch(themePrefsProvider);
    final mode = ThemeMode.values.asNameMap()[prefs.modeName] ??
        AppTheme.defaultTheme.mode;
    final seed = AppColorSeed.values.asNameMap()[prefs.seedName] ??
        AppTheme.defaultTheme.seed;
    return AppTheme(mode: mode, seed: seed);
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    await ref.read(themePrefsProvider).save(mode: mode);
  }

  Future<void> setSeed(AppColorSeed seed) async {
    state = state.copyWith(seed: seed);
    await ref.read(themePrefsProvider).save(seed: seed);
  }
}

final appThemeProvider =
    NotifierProvider<AppThemeController, AppTheme>(AppThemeController.new);