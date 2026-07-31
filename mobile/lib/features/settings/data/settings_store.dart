import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted app settings (API base URL, device display name).
/// Registered via [AppRegisterModule] (`@preResolve`).
class SettingsStore {
  SettingsStore(this._prefs, this._log);

  final SharedPreferences _prefs;
  final AppLog _log;

  static const defaultBaseUrl = 'http://10.0.2.2:8787';
  static const defaultDeviceName = 'android';

  static const _kBaseUrl = 'base_url';
  static const _kDeviceName = 'device_name';
  static const _kDeviceId = 'device_id';

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
