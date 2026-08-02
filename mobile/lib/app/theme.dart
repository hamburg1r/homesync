import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

/// Builds light/dark [ThemeData] from dynamic ColorSchemes or brand seed.
({ThemeData light, ThemeData dark}) homesyncThemes({
  required bool useDynamicColor,
  ColorScheme? lightDynamic,
  ColorScheme? darkDynamic,
}) {
  final lightScheme = _resolveScheme(
    useDynamicColor: useDynamicColor,
    dynamicScheme: lightDynamic,
    brightness: Brightness.light,
  );
  final darkScheme = _resolveScheme(
    useDynamicColor: useDynamicColor,
    dynamicScheme: darkDynamic,
    brightness: Brightness.dark,
  );
  return (
    light: _themeFromScheme(lightScheme),
    dark: _themeFromScheme(darkScheme),
  );
}

ColorScheme _resolveScheme({
  required bool useDynamicColor,
  required ColorScheme? dynamicScheme,
  required Brightness brightness,
}) {
  if (useDynamicColor && dynamicScheme != null) {
    return dynamicScheme.harmonized();
  }
  return ColorScheme.fromSeed(
    seedColor: SettingsStore.brandSeed,
    brightness: brightness,
  );
}

ThemeData _themeFromScheme(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
  );
}
