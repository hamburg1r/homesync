import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
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

  Future<Uint8List> getThumb({required String fileId}) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'GET /v1/thumbs/…',
      _client.get(_uri('/v1/thumbs/$fileId')),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('thumb not found', statusCode: 404);
    }
    if (response.statusCode == 415) {
      throw HomesyncApiException('thumb unsupported', statusCode: 415);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'thumb download failed',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<List<CatalogFile>> searchFiles({
    required String q,
    int limit = 100,
  }) async {
    refreshBaseUrlFromSettings();
    final query = <String, String>{'limit': '$limit', 'q': q};
    final response = await _send(
      'GET /v1/files?q=…',
      _client.get(_uri('/v1/files', query)),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'file search failed',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => CatalogFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> putBlob({
    required String algo,
    required String hexHash,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) {
    return putBlobStream(
      algo: algo,
      hexHash: hexHash,
      contentLength: bytes.length,
      body: Stream<List<int>>.fromIterable(
        _chunkBytes(bytes, ContentHash.chunkSize),
      ),
      onProgress: onProgress,
    );
  }

  /// Streamed one-shot CAS upload (kept for small / legacy callers).
  Future<void> putBlobStream({
    required String algo,
    required String hexHash,
    required int contentLength,
    required Stream<List<int>> body,
    void Function(int sent, int total)? onProgress,
  }) async {
    refreshBaseUrlFromSettings();
    final request = http.StreamedRequest(
      'PUT',
      _uri('/v1/blobs/$algo/$hexHash'),
    );
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = contentLength;

    // Large uploads: scale timeout with size (min 2m, ~1s per MiB, cap 6h).
    final uploadTimeout = Duration(
      seconds: (120 + (contentLength ~/ (1024 * 1024))).clamp(120, 6 * 3600),
    );

    try {
      final responseFuture = _client.send(request).timeout(uploadTimeout);
      var sent = 0;
      await for (final chunk in body) {
        request.sink.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, contentLength);
      }
      await request.sink.close();
      final streamed = await responseFuture;
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 60));
      _log.fine('api', 'PUT /v1/blobs/… → HTTP ${response.statusCode}');
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw HomesyncApiException(
          'blob upload failed',
          statusCode: response.statusCode,
        );
      }
    } on TimeoutException {
      _log.error('api', 'PUT /v1/blobs timed out');
      throw HomesyncApiException('request timed out');
    } on SocketException catch (e) {
      _log.error('api', 'PUT /v1/blobs network error', e);
      throw HomesyncApiException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      _log.error('api', 'PUT /v1/blobs client error', e);
      throw HomesyncApiException('network error: ${e.message}');
    }
  }

  /// Chunk size for resumable PATCH uploads (server acks each offset).
  static const uploadChunkSize = 4 * 1024 * 1024;

  /// Per-chunk idle timeout: last byte of a chunk within this window is OK.
  static const chunkTimeout = Duration(hours: 1);

  /// Resumable CAS upload: begin session → PATCH chunks → server offset ack.
  ///
  /// [readAt] returns up to [length] bytes starting at [offset]. On stall or
  /// disconnect, the client re-GETs status and continues from the acked offset.
  Future<void> putBlobResumable({
    required String algo,
    required String hexHash,
    required int contentLength,
    required Future<Uint8List> Function(int offset, int length) readAt,
    void Function(int sent, int total)? onProgress,
    int chunkSize = uploadChunkSize,
  }) async {
    refreshBaseUrlFromSettings();
    final begin = await _send(
      'POST /v1/blob-uploads',
      _client.post(
        _uri('/v1/blob-uploads'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'algo': algo,
          'content_hash': hexHash,
          'size_bytes': contentLength,
        }),
      ),
    );
    if (begin.statusCode != 200) {
      throw HomesyncApiException(
        'blob upload begin failed',
        statusCode: begin.statusCode,
      );
    }
    final beginJson = jsonDecode(begin.body) as Map<String, dynamic>;
    final uploadId = beginJson['upload_id'] as String;
    var offset = beginJson['offset'] as int;
    final complete = beginJson['complete'] as bool? ?? false;
    onProgress?.call(offset, contentLength);
    if (complete || offset >= contentLength) {
      _log.fine('api', 'blob upload already complete ($uploadId)');
      return;
    }

    var attempt = 0;
    while (offset < contentLength) {
      final length = (contentLength - offset).clamp(0, chunkSize);
      final chunk = await readAt(offset, length);
      if (chunk.isEmpty && length > 0) {
        throw HomesyncApiException('read returned empty at offset $offset');
      }

      try {
        final response = await _client
            .patch(
              _uri('/v1/blob-uploads/$uploadId'),
              headers: {
                'Content-Type': 'application/octet-stream',
                'Upload-Offset': '$offset',
                'Content-Length': '${chunk.length}',
              },
              body: chunk,
            )
            .timeout(chunkTimeout);
        _log.fine(
          'api',
          'PATCH /v1/blob-uploads/… @$offset +${chunk.length} '
          '→ HTTP ${response.statusCode}',
        );

        if (response.statusCode == 409) {
          final serverOff = int.tryParse(
            response.headers['upload-offset'] ?? '',
          );
          if (serverOff != null) {
            offset = serverOff;
            onProgress?.call(offset, contentLength);
            attempt = 0;
            continue;
          }
          throw HomesyncApiException(
            'blob upload offset conflict',
            statusCode: 409,
          );
        }
        if (response.statusCode == 410) {
          throw HomesyncApiException(
            'blob upload expired; restart',
            statusCode: 410,
          );
        }
        if (response.statusCode != 204 && response.statusCode != 200) {
          throw HomesyncApiException(
            'blob upload chunk failed',
            statusCode: response.statusCode,
          );
        }

        final acked = int.tryParse(response.headers['upload-offset'] ?? '');
        if (acked == null) {
          throw HomesyncApiException('missing Upload-Offset ack');
        }
        offset = acked;
        onProgress?.call(offset, contentLength);
        attempt = 0;

        final done = response.headers['x-upload-complete'] == '1';
        if (done || offset >= contentLength) {
          return;
        }
      } on TimeoutException {
        _log.warn('api', 'chunk timed out at $offset; polling resume');
        offset = await _pollUploadOffset(uploadId, contentLength);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        await Future<void>.delayed(_retryDelay(attempt));
      } on SocketException catch (e) {
        _log.warn('api', 'chunk network error at $offset: $e; resume');
        offset = await _pollUploadOffset(uploadId, contentLength);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > 12) {
          throw HomesyncApiException('network error: ${e.message}');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on http.ClientException catch (e) {
        _log.warn('api', 'chunk client error at $offset: $e; resume');
        offset = await _pollUploadOffset(uploadId, contentLength);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > 12) {
          throw HomesyncApiException('network error: ${e.message}');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on HomesyncApiException {
        rethrow;
      }
    }
  }

  Future<int> _pollUploadOffset(String uploadId, int contentLength) async {
    final status = await _send(
      'GET /v1/blob-uploads/$uploadId',
      _client.get(_uri('/v1/blob-uploads/$uploadId')),
    );
    if (status.statusCode == 404) {
      // Session wiped after finalize — treat as complete.
      return contentLength;
    }
    if (status.statusCode != 200) {
      throw HomesyncApiException(
        'blob upload status failed',
        statusCode: status.statusCode,
      );
    }
    final json = jsonDecode(status.body) as Map<String, dynamic>;
    if (json['complete'] == true) {
      return contentLength;
    }
    return json['offset'] as int;
  }

  static Duration _retryDelay(int attempt) {
    final seconds = (1 << attempt.clamp(0, 6)).clamp(1, 60);
    return Duration(seconds: seconds);
  }

  static Iterable<List<int>> _chunkBytes(Uint8List bytes, int chunkSize) sync* {
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield bytes.sublist(offset, end);
      offset = end;
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

  /// Soft-delete on the PC catalog (sets `deleted_at`; blob GC deferred).
  Future<CatalogFile> deleteFile(String fileId) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'DELETE /v1/files/$fileId',
      _client.delete(_uri('/v1/files/$fileId')),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('file not found', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'file delete failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}
