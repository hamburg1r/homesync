import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

/// Stable client-generated device UUID (survives restarts; not reinstalls).
@lazySingleton
class DeviceIdentity {
  DeviceIdentity(this._settings, this._log);

  final SettingsStore _settings;
  final AppLog _log;
  static const _uuid = Uuid();

  Future<String> ensureDeviceId() async {
    final existing = _settings.deviceId;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final id = _uuid.v4();
    await _settings.setDeviceId(id);
    _log.info('di', 'created device_id=$id');
    return id;
  }
}
