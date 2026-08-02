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

  /// Currently stored id, if any (does not create).
  String? get currentDeviceId {
    final id = _settings.deviceId;
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<String> ensureDeviceId() async {
    final existing = currentDeviceId;
    if (existing != null) {
      return existing;
    }
    final id = _uuid.v4();
    await _settings.setDeviceId(id);
    _log.info('di', 'created device_id=$id');
    return id;
  }

  /// Bind this install to an existing server ``device_id`` (reclaim after reinstall).
  Future<void> reclaim(String deviceId) async {
    final id = deviceId.trim();
    if (id.isEmpty) {
      throw ArgumentError('device_id must be non-empty');
    }
    if (id.length > 36) {
      throw ArgumentError('device_id must be at most 36 characters');
    }
    await _settings.setDeviceId(id);
    _log.info('di', 'reclaimed device_id=$id');
  }

  /// Mint a fresh identity (abandons previous ``device_id`` on this install).
  Future<String> resetToNew() async {
    final id = _uuid.v4();
    await _settings.setDeviceId(id);
    _log.info('di', 'reset device_id=$id');
    return id;
  }
}
