import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/app/theme.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('appearance settings', () {
    late SettingsStore settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.open(AppLog());
    });

    test('defaults to system theme and dynamic color on', () {
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.useDynamicColor, isTrue);
    });

    test('persists theme mode and notifies listeners', () async {
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setThemeMode(ThemeMode.dark);
      expect(settings.themeMode, ThemeMode.dark);
      expect(notified, 1);

      await settings.setThemeMode(ThemeMode.light);
      expect(settings.themeMode, ThemeMode.light);
      expect(notified, 2);

      await settings.setThemeMode(ThemeMode.system);
      expect(settings.themeMode, ThemeMode.system);
      expect(notified, 3);
    });

    test('persists dynamic color toggle', () async {
      await settings.setUseDynamicColor(false);
      expect(settings.useDynamicColor, isFalse);

      final reopened = await SettingsStore.open(AppLog());
      expect(reopened.useDynamicColor, isFalse);
      expect(reopened.themeMode, ThemeMode.system);
    });
  });

  group('homesyncThemes', () {
    test('uses brand seed when dynamic color disabled', () {
      final themes = homesyncThemes(useDynamicColor: false);
      expect(themes.light.colorScheme.brightness, Brightness.light);
      expect(themes.dark.colorScheme.brightness, Brightness.dark);
      expect(themes.light.useMaterial3, isTrue);
    });

    test('prefers dynamic schemes when enabled', () {
      final lightDyn = ColorScheme.fromSeed(
        seedColor: const Color(0xFFAA00FF),
        brightness: Brightness.light,
      );
      final darkDyn = ColorScheme.fromSeed(
        seedColor: const Color(0xFFAA00FF),
        brightness: Brightness.dark,
      );
      final themes = homesyncThemes(
        useDynamicColor: true,
        lightDynamic: lightDyn,
        darkDynamic: darkDyn,
      );
      expect(themes.light.colorScheme.primary, isNot(equals(
        ColorScheme.fromSeed(
          seedColor: SettingsStore.brandSeed,
          brightness: Brightness.light,
        ).primary,
      )));
    });
  });
}
