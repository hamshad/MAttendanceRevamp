import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../utils/constants.dart';

// ── Theme mode provider ────────────────────────────────────────────────────────

const _themeModeKey = 'themeModeIndex';

/// Reads the persisted ThemeMode from Hive on startup.
ThemeMode _loadThemeMode() {
  final box = Hive.box(AppConstants.cacheBox);
  final index = box.get(_themeModeKey, defaultValue: ThemeMode.light.index) as int;
  return ThemeMode.values[index];
}

/// Persists the selected ThemeMode to Hive.
Future<void> _saveThemeMode(ThemeMode mode) =>
    Hive.box(AppConstants.cacheBox).put(_themeModeKey, mode.index);

/// Reactive ThemeMode — backed by Hive for persistence across restarts.
final themeModeProvider = StateProvider<ThemeMode>(
  (ref) => _loadThemeMode(),
);

/// Convenience notifier so the profile toggle can call a single method.
extension ThemeModeNotifier on StateController<ThemeMode> {
  void toggle() {
    final next = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    state = next;
    _saveThemeMode(next);
  }

  void setMode(ThemeMode mode) {
    state = mode;
    _saveThemeMode(mode);
  }
}
