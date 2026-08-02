import 'package:flutter/material.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted app settings (API base URL, device display name, appearance).
/// Registered via [AppRegisterModule] (`@preResolve`).
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, this._log);

  final SharedPreferences _prefs;
  final AppLog _log;

  static const defaultBaseUrl = 'http://10.0.2.2:8787';
  static const defaultDeviceName = 'android';

  /// Default pin disk budget: 512 MiB.
  static const defaultPinBudgetBytes = 512 * 1024 * 1024;

  /// Brand seed when dynamic color is off or unavailable (pre-Android 12).
  static const brandSeed = Color(0xFF2F5D50);

  static const _kBaseUrl = 'base_url';
  static const _kDeviceName = 'device_name';
  static const _kDeviceId = 'device_id';
  static const _kPinBudgetBytes = 'pin_budget_bytes';
  static const _kThemeMode = 'theme_mode';
  static const _kUseDynamicColor = 'use_dynamic_color';
  static const _kSyncEnabled = 'sync_enabled';
  static const _kPinDestinationDir = 'pin_destination_dir';

  /// Prefer DI `@preResolve`; available for tests.
  static Future<SettingsStore> open(AppLog log) async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore(prefs, log);
  }

  String get baseUrl => _prefs.getString(_kBaseUrl) ?? defaultBaseUrl;

  Future<void> setBaseUrl(String value) async {
    final err = validateBaseUrl(value);
    if (err != null) {
      throw ArgumentError(err);
    }
    await _prefs.setString(_kBaseUrl, value.trim());
    _log.info('settings', 'base_url set to ${value.trim()}');
  }

  String get deviceName =>
      _prefs.getString(_kDeviceName) ?? defaultDeviceName;

  Future<void> setDeviceName(String value) async {
    await _prefs.setString(_kDeviceName, value.trim());
    _log.info('settings', 'device_name set to ${value.trim()}');
  }

  String? get deviceId => _prefs.getString(_kDeviceId);

  Future<void> setDeviceId(String value) async {
    await _prefs.setString(_kDeviceId, value);
  }

  int get pinBudgetBytes =>
      _prefs.getInt(_kPinBudgetBytes) ?? defaultPinBudgetBytes;

  Future<void> setPinBudgetBytes(int value) async {
    if (value < 0) {
      throw ArgumentError('pin budget must be non-negative');
    }
    await _prefs.setInt(_kPinBudgetBytes, value);
    _log.info('settings', 'pin_budget_bytes set to $value');
  }

  /// `system` (default), `light`, or `dark`.
  ThemeMode get themeMode {
    switch (_prefs.getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final wire = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _prefs.setString(_kThemeMode, wire);
    _log.info('settings', 'theme_mode set to $wire');
    notifyListeners();
  }

  /// When true (default), use wallpaper/system dynamic ColorScheme on Android 12+.
  bool get useDynamicColor =>
      _prefs.getBool(_kUseDynamicColor) ?? true;

  Future<void> setUseDynamicColor(bool value) async {
    await _prefs.setBool(_kUseDynamicColor, value);
    _log.info('settings', 'use_dynamic_color set to $value');
    notifyListeners();
  }

  /// When false, catalog delta + tracking ingest are skipped (local browse only).
  bool get syncEnabled => _prefs.getBool(_kSyncEnabled) ?? true;

  Future<void> setSyncEnabled(bool value) async {
    await _prefs.setBool(_kSyncEnabled, value);
    _log.info('settings', 'sync_enabled set to $value');
    notifyListeners();
  }

  /// Default folder for PC→phone materialize (empty = app `homesync_pins` CAS).
  String? get pinDestinationDir {
    final raw = _prefs.getString(_kPinDestinationDir)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> setPinDestinationDir(String? value) async {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _prefs.remove(_kPinDestinationDir);
      _log.info('settings', 'pin_destination_dir cleared (app default)');
    } else {
      await _prefs.setString(_kPinDestinationDir, trimmed);
      _log.info('settings', 'pin_destination_dir set to $trimmed');
    }
    notifyListeners();
  }

  /// Low-level string prefs for durable queues (ingest, etc.).
  String? readRaw(String key) => _prefs.getString(key);

  Future<void> writeRaw(String key, String value) async {
    await _prefs.setString(key, value);
  }

  /// Returns an error message if [raw] is not a usable http(s) base URL.
  static String? validateBaseUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) {
      return 'URL is required';
    }
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Enter a valid URL (e.g. http://10.0.2.2:8787)';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'URL must use http or https';
    }
    return null;
  }
}
