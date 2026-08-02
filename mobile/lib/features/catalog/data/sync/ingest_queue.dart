import 'dart:convert';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

/// Durable pending phone→PC uploads (blobs → file row → availability).
///
/// Stored in SharedPreferences so a reconnect can flush without re-picking
/// the camera photo (bytes must already live in [LocalBlobStore]).
@lazySingleton
class IngestQueue {
  IngestQueue(this._settings, this._log);

  final SettingsStore _settings;
  final AppLog _log;

  static const _kQueue = 'ingest_queue_v1';

  Future<List<IngestQueueItem>> list() async {
    final raw = _settings.readRaw(_kQueue);
    if (raw == null || raw.isEmpty) return <IngestQueueItem>[];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => IngestQueueItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> enqueue(IngestQueueItem item) async {
    final items = await list();
    items.add(item);
    await _persist(items);
    _log.info('ingest', 'queued ${item.id} ${item.title ?? item.contentHash}');
  }

  Future<void> remove(String id) async {
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await _persist(items);
  }

  Future<void> _persist(List<IngestQueueItem> items) async {
    await _settings.writeRaw(
      _kQueue,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  static IngestQueueItem newItem({
    required String contentHash,
    required String hashAlgo,
    required int sizeBytes,
    String? mimeType,
    String? title,
    String sourceKind = 'camera',
  }) {
    return IngestQueueItem(
      id: const Uuid().v4(),
      contentHash: contentHash,
      hashAlgo: hashAlgo,
      sizeBytes: sizeBytes,
      mimeType: mimeType,
      title: title,
      sourceKind: sourceKind,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

class IngestQueueItem {
  const IngestQueueItem({
    required this.id,
    required this.contentHash,
    required this.hashAlgo,
    required this.sizeBytes,
    this.mimeType,
    this.title,
    this.sourceKind = 'camera',
    required this.createdAt,
  });

  final String id;
  final String contentHash;
  final String hashAlgo;
  final int sizeBytes;
  final String? mimeType;
  final String? title;
  final String sourceKind;
  final String createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'content_hash': contentHash,
        'hash_algo': hashAlgo,
        'size_bytes': sizeBytes,
        'mime_type': mimeType,
        'title': title,
        'source_kind': sourceKind,
        'created_at': createdAt,
      };

  factory IngestQueueItem.fromJson(Map<String, dynamic> json) {
    return IngestQueueItem(
      id: json['id'] as String,
      contentHash: json['content_hash'] as String,
      hashAlgo: json['hash_algo'] as String? ?? 'blake3',
      sizeBytes: json['size_bytes'] as int,
      mimeType: json['mime_type'] as String?,
      title: json['title'] as String?,
      sourceKind: json['source_kind'] as String? ?? 'camera',
      createdAt: json['created_at'] as String,
    );
  }
}
