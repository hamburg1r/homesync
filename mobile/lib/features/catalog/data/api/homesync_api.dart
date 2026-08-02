import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Thin HTTP client for Homesync `/v1` (catalog, devices, availability, blobs).
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

  Future<AvailabilityInfo> putAvailability({
    required String fileId,
    required String deviceId,
    required String mode,
    String? updatedAt,
    String? baseUpdatedAt,
  }) async {
    refreshBaseUrlFromSettings();
    final body = <String, dynamic>{'mode': mode};
    if (updatedAt != null) body['updated_at'] = updatedAt;
    if (baseUpdatedAt != null) body['base_updated_at'] = baseUpdatedAt;
    final response = await _send(
      'PUT /v1/files/…/availability',
      _client.put(
        _uri('/v1/files/$fileId/availability/$deviceId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'availability update failed',
        statusCode: response.statusCode,
      );
    }
    return AvailabilityInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<Uint8List> getBlob({
    required String algo,
    required String hexHash,
  }) async {
    refreshBaseUrlFromSettings();
    // Blob downloads may be larger; allow a longer timeout.
    final response = await _send(
      'GET /v1/blobs/$algo/…',
      _client.get(_uri('/v1/blobs/$algo/$hexHash')).timeout(
            const Duration(seconds: 120),
          ),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('blob not found', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'blob download failed',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<void> putBlob({
    required String algo,
    required String hexHash,
    required Uint8List bytes,
  }) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'PUT /v1/blobs/$algo/…',
      _client
          .put(
            _uri('/v1/blobs/$algo/$hexHash'),
            headers: {'Content-Type': 'application/octet-stream'},
            body: bytes,
          )
          .timeout(const Duration(seconds: 120)),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw HomesyncApiException(
        'blob upload failed',
        statusCode: response.statusCode,
      );
    }
  }

  Future<CatalogFile> createFile(FileCreateRequest request) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'POST /v1/files',
      _client.post(
        _uri('/v1/files'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      ),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'file create failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}
