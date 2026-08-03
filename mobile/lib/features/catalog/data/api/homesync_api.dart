import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
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
  HomesyncApi(SettingsStore settings, this._log)
      : _settings = settings,
        _client = http.Client(),
        _baseUrl = _normalizeBase(settings.baseUrl),
        timeout = const Duration(seconds: 15);

  /// Test / custom HTTP client.
  HomesyncApi.withClient(
    SettingsStore settings,
    this._log,
    http.Client client, {
    this.timeout = const Duration(seconds: 15),
  })  : _settings = settings,
        _client = client,
        _baseUrl = _normalizeBase(settings.baseUrl);

  /// Pure-Dart client for the FG task isolate (no SharedPreferences / Drift).
  HomesyncApi.detached({
    required String baseUrl,
    AppLog? log,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : _settings = null,
        _log = log ?? AppLog.silent(),
        _client = client ?? http.Client(),
        _baseUrl = _normalizeBase(baseUrl);

  final SettingsStore? _settings;
  final AppLog _log;
  String _baseUrl;
  final http.Client _client;
  final Duration timeout;

  String get baseUrl => _baseUrl;

  void refreshBaseUrlFromSettings() {
    final settings = _settings;
    if (settings == null) return;
    _baseUrl = _normalizeBase(settings.baseUrl);
  }

  set baseUrl(String value) {
    _baseUrl = _normalizeBase(value);
  }

  void close() => _client.close();

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

  /// Extract FastAPI ``detail`` string (or leave null) for error messages.
  static String? _httpDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final d = decoded['detail'];
        if (d is String) return d;
        if (d != null) return d.toString();
      }
    } catch (_) {}
    final t = body.trim();
    if (t.isEmpty) return null;
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }

  Future<http.Response> _send(
    String op,
    Future<http.Response> future, {
    Duration? timeoutOverride,
  }) async {
    final limit = timeoutOverride ?? timeout;
    try {
      final response = await future.timeout(limit);
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

  Future<List<DeviceInfo>> listDevices() async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'GET /v1/devices',
      _client.get(_uri('/v1/devices')),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'list devices failed',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CatalogDelta> catalogDelta({
    String? since,
    String? purgeSince,
    int limit = 500,
  }) async {
    refreshBaseUrlFromSettings();
    final query = <String, String>{'limit': '$limit'};
    if (since != null && since.isNotEmpty) {
      query['since'] = since;
    }
    if (purgeSince != null && purgeSince.isNotEmpty) {
      query['purge_since'] = purgeSince;
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
  /// Scale idle timeouts with payload size (min 2m, ~1s/MiB, cap 6h).
  Duration _uploadIdleTimeout(int contentLength) {
    final mb = (contentLength / (1024 * 1024)).ceil().clamp(1, 100000);
    return Duration(seconds: (120 + mb).clamp(120, 6 * 3600));
  }

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
    // Begin may touch large existing blobs / slow VPN; do not use the 15s
    // catalog timeout.
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
      timeoutOverride: _uploadIdleTimeout(contentLength),
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
    const maxAttempts = 60; // ~30m with 30s cap — covers leaving LAN and coming back
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
          final recovered = await _recoverUploadOffset(
            uploadId: uploadId,
            contentLength: contentLength,
            response: response,
            fallback: offset,
          );
          if (recovered != null) {
            if (recovered >= contentLength) {
              return;
            }
            offset = recovered;
            onProgress?.call(offset, contentLength);
            attempt = 0;
            continue;
          }
          final detail = _responseDetail(response);
          throw HomesyncApiException(
            detail.isEmpty
                ? 'blob upload conflict'
                : 'blob upload conflict: $detail',
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
        _log.warn('api', 'chunk timed out at $offset; will retry');
        offset = await _pollUploadOffsetOrKeep(uploadId, contentLength, offset);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > maxAttempts) {
          throw HomesyncApiException('request timed out');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on SocketException catch (e) {
        _log.warn('api', 'chunk network error at $offset: $e; will retry');
        offset = await _pollUploadOffsetOrKeep(uploadId, contentLength, offset);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > maxAttempts) {
          throw HomesyncApiException('network error: ${e.message}');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on http.ClientException catch (e) {
        _log.warn('api', 'chunk client error at $offset: $e; will retry');
        offset = await _pollUploadOffsetOrKeep(uploadId, contentLength, offset);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > maxAttempts) {
          throw HomesyncApiException('network error: ${e.message}');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on HttpException catch (e) {
        // e.g. "Connection closed before full header was received"
        _log.warn('api', 'chunk HTTP error at $offset: $e; will retry');
        offset = await _pollUploadOffsetOrKeep(uploadId, contentLength, offset);
        onProgress?.call(offset, contentLength);
        attempt += 1;
        if (attempt > maxAttempts) {
          throw HomesyncApiException('network error: ${e.message}');
        }
        await Future<void>.delayed(_retryDelay(attempt));
      } on HomesyncApiException {
        rethrow;
      }
    }
  }

  /// Prefer server offset after a blip; if still offline, keep [fallback].
  Future<int> _pollUploadOffsetOrKeep(
    String uploadId,
    int contentLength,
    int fallback,
  ) async {
    try {
      return await _pollUploadOffset(uploadId, contentLength);
    } catch (e) {
      _log.warn('api', 'upload status unreachable: $e; keeping offset $fallback');
      return fallback;
    }
  }

  /// Sync local offset after HTTP 409: header, body, then GET status.
  ///
  /// Returns null when the conflict is not an offset mismatch (e.g. hash).
  Future<int?> _recoverUploadOffset({
    required String uploadId,
    required int contentLength,
    required http.Response response,
    required int fallback,
  }) async {
    final fromHeader = int.tryParse(
      response.headers['upload-offset'] ?? '',
    );
    if (fromHeader != null) {
      return fromHeader;
    }

    final detail = _responseDetail(response);
    final fromBody = RegExp(r'server=(\d+)').firstMatch(detail);
    if (fromBody != null) {
      return int.parse(fromBody.group(1)!);
    }

    // Hash / size conflicts are not resumable via offset alone.
    final lower = detail.toLowerCase();
    if (lower.contains('hash mismatch') ||
        lower.contains('size mismatch') ||
        lower.contains('blob collision') ||
        lower.contains('exceed size')) {
      return null;
    }

    try {
      final polled = await _pollUploadOffset(uploadId, contentLength);
      if (polled != fallback || polled > 0) {
        _log.warn(
          'api',
          '409 without Upload-Offset; resumed via status at $polled',
        );
        return polled;
      }
    } catch (e) {
      _log.warn('api', '409 recovery status failed: $e');
    }
    return null;
  }

  static String _responseDetail(http.Response response) {
    final raw = response.body.trim();
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {
      // plain text body
    }
    return raw;
  }

  Future<int> _pollUploadOffset(String uploadId, int contentLength) async {
    final status = await _send(
      'GET /v1/blob-uploads/$uploadId',
      _client.get(_uri('/v1/blob-uploads/$uploadId')),
      timeoutOverride: const Duration(seconds: 20),
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
    // 1s, 2s, 4s… capped at 30s so LAN return is noticed reasonably soon.
    final seconds = (1 << attempt.clamp(0, 5)).clamp(1, 30);
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

  /// Archive current head and set a new content hash (blob must exist).
  ///
  /// Throws [KdbxConflictPendingException] on HTTP 202 (outbox opened).
  Future<CatalogFile> updateFileContent(
    String fileId,
    FileContentRequest request,
  ) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'POST /v1/files/$fileId/content',
      _client.post(
        _uri('/v1/files/$fileId/content'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      ),
    );
    if (response.statusCode == 202) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final conflictJson = body['conflict'] as Map<String, dynamic>;
      throw KdbxConflictPendingException(KdbxConflict.fromJson(conflictJson));
    }
    if (response.statusCode == 404) {
      throw HomesyncApiException('file not found', statusCode: 404);
    }
    if (response.statusCode == 409) {
      throw HomesyncApiException(
        'content hash already used by another file',
        statusCode: 409,
      );
    }
    if (response.statusCode != 200) {
      final detail = _httpDetail(response.body);
      throw HomesyncApiException(
        detail == null
            ? 'file content update failed'
            : 'file content update failed: $detail',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> putKdbxSecret(String fileId, String password) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'PUT /v1/files/$fileId/kdbx-secret',
      _client.put(
        _uri('/v1/files/$fileId/kdbx-secret'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'password': password}),
      ),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('file not found', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'kdbx secret update failed',
        statusCode: response.statusCode,
      );
    }
  }

  Future<List<KdbxConflict>> listConflicts({String? state = 'active'}) async {
    refreshBaseUrlFromSettings();
    final query = <String, String>{};
    if (state != null) query['state'] = state;
    final response = await _send(
      'GET /v1/conflicts',
      _client.get(_uri('/v1/conflicts', query.isEmpty ? null : query)),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'list conflicts failed',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return [
      for (final e in list) KdbxConflict.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<KdbxConflict> getConflict(String conflictId) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'GET /v1/conflicts/$conflictId',
      _client.get(_uri('/v1/conflicts/$conflictId')),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('conflict not found', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'get conflict failed',
        statusCode: response.statusCode,
      );
    }
    return KdbxConflict.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<CatalogFile> resolveConflict(
    String conflictId,
    KdbxResolveRequest request,
  ) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'POST /v1/conflicts/$conflictId/resolve',
      _client.post(
        _uri('/v1/conflicts/$conflictId/resolve'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      ),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('conflict not found', statusCode: 404);
    }
    if (response.statusCode == 409) {
      throw HomesyncApiException(
        _httpDetail(response.body) ?? 'conflict resolve stale',
        statusCode: 409,
      );
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        _httpDetail(response.body) ?? 'conflict resolve failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Re-classify stored candidates after the vault secret is set.
  ///
  /// Returns a [CatalogFile] if auto-resolved, otherwise the refreshed conflict.
  Future<Object> recheckConflict(String conflictId) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'POST /v1/conflicts/$conflictId/recheck',
      _client.post(_uri('/v1/conflicts/$conflictId/recheck')),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('conflict not found', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        _httpDetail(response.body) ?? 'conflict recheck failed',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['status'] == 'conflict' && body['conflict'] is Map) {
      return KdbxConflict.fromJson(body['conflict'] as Map<String, dynamic>);
    }
    return CatalogFile.fromJson(body);
  }

  /// Soft-delete on the PC catalog (sets `deleted_at`; hard-purge via GC).
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

  /// Patch catalog metadata (title/notes/source_kind).
  Future<CatalogFile> patchFile(
    String fileId, {
    String? title,
    String? notes,
    String? sourceKind,
    String? baseUpdatedAt,
  }) async {
    refreshBaseUrlFromSettings();
    final body = <String, dynamic>{
      'title': ?title,
      'notes': ?notes,
      'source_kind': ?sourceKind,
      'base_updated_at': ?baseUpdatedAt,
    };
    final response = await _send(
      'PATCH /v1/files/$fileId',
      _client.patch(
        _uri('/v1/files/$fileId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('file not found', statusCode: 404);
    }
    if (response.statusCode == 400) {
      throw HomesyncApiException(
        'invalid file patch',
        statusCode: 400,
      );
    }
    if (response.statusCode == 409) {
      throw HomesyncApiException('catalog conflict', statusCode: 409);
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'file patch failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Replace all tags on a file (server creates missing tag names).
  Future<CatalogFile> putFileTags({
    required String fileId,
    required List<String> tags,
  }) async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'PUT /v1/files/…/tags',
      _client.put(
        _uri('/v1/files/$fileId/tags'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'tags': tags}),
      ),
    );
    if (response.statusCode == 404) {
      throw HomesyncApiException('file not found', statusCode: 404);
    }
    if (response.statusCode == 400) {
      throw HomesyncApiException(
        'invalid tags',
        statusCode: 400,
      );
    }
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'set file tags failed',
        statusCode: response.statusCode,
      );
    }
    return CatalogFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<CatalogTag>> listTags() async {
    refreshBaseUrlFromSettings();
    final response = await _send(
      'GET /v1/tags',
      _client.get(_uri('/v1/tags')),
    );
    if (response.statusCode != 200) {
      throw HomesyncApiException(
        'list tags failed',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => CatalogTag.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
