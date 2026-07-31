import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:http/http.dart' as http;
import 'package:injectable/injectable.dart';

class HomesyncApiException implements Exception {
  HomesyncApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// Thin HTTP client for Homesync `/v1` (catalog + devices). No blob downloads.
@lazySingleton
class HomesyncApi {
  HomesyncApi(this._settings, this._log)
      : _client = http.Client(),
        _baseUrl = _normalizeBase(_settings.baseUrl),
        timeout = const Duration(seconds: 15);

  /// Test / custom HTTP client.
  HomesyncApi.withClient(
    this._settings,
    this._log,
    http.Client client, {
    this.timeout = const Duration(seconds: 15),
  })  : _client = client,
        _baseUrl = _normalizeBase(_settings.baseUrl);

  final SettingsStore _settings;
  final AppLog _log;
  String _baseUrl;
  final http.Client _client;
  final Duration timeout;

  String get baseUrl => _baseUrl;

  void refreshBaseUrlFromSettings() {
    _baseUrl = _normalizeBase(_settings.baseUrl);
  }

  set baseUrl(String value) {
    _baseUrl = _normalizeBase(value);
  }

  static String _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$_baseUrl$path').replace(queryParameters: query);
  }

  Future<http.Response> _send(String op, Future<http.Response> future) async {
    try {
      final response = await future.timeout(timeout);
      _log.fine('api', '$op → HTTP ${response.statusCode}');
      return response;
    } on TimeoutException {
      _log.error('api', '$op timed out');
      throw HomesyncApiException('request timed out');
    } on SocketException catch (e) {
      _log.error('api', '$op network error', e);
      throw HomesyncApiException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      _log.error('api', '$op client error', e);
      throw HomesyncApiException('network error: ${e.message}');
    }
  }

  Future<DeviceInfo> registerDevice({
    required String deviceId,
    required String name,
    String kind = 'android',
  }) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'POST /v1/devices',
      _client.post(
        _uri('/v1/devices'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': deviceId,
          'name': name,
          'kind': kind,
        }),
      ),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'device registration failed',
        statusCode: response.statusCode,
      );
    }
    final info = DeviceInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    _log.info('api', 'registered device ${info.deviceId} (${info.name})');
    return info;
  }

  Future<CatalogDelta> catalogDelta({
    String? since,
    int limit = 500,
  }) async {
    refreshBaseUrlFromSettings();
    final query = <String, String>{'limit': '$limit'};
    if (since != null && since.isNotEmpty) {
      query['since'] = since;
    }
    final response = await _send(
      'GET /v1/catalog/delta',
      _client.get(_uri('/v1/catalog/delta', query)),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'catalog delta failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogDelta.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}
