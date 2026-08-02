import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:injectable/injectable.dart';

class IngestException implements Exception {
  IngestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Phone → PC ingest: hash → local store → queue → PUT blob → POST file → pin.
@lazySingleton
class IngestService {
  IngestService({
    required this.api,
    required this.repository,
    required this.blobs,
    required this.identity,
    required this.queue,
    required this.log,
  });

  final HomesyncApi api;
  final CatalogRepository repository;
  final LocalBlobStore blobs;
  final DeviceIdentity identity;
  final IngestQueue queue;
  final AppLog log;

  /// Ingest bytes now (or leave durable queue entries if the network fails).
  Future<CatalogFile> ingestBytes(
    Uint8List bytes, {
    String? title,
    String? mimeType,
    String sourceKind = 'misc',
    String? relativePath,
  }) async {
    final hash = ContentHash.blake3Hex(bytes);
    await blobs.write(ContentHash.algo, hash, bytes);

    final item = IngestQueue.newItem(
      contentHash: hash,
      hashAlgo: ContentHash.algo,
      sizeBytes: bytes.length,
      mimeType: mimeType,
      title: title,
      sourceKind: sourceKind,
      relativePath: relativePath,
    );
    await queue.enqueue(item);

    try {
      final file = await _flushItem(item);
      await queue.remove(item.id);
      return file;
    } catch (e) {
      log.warn('ingest', 'queued for retry after failure: $e');
      rethrow;
    }
  }

  /// Flush any durable queue items (call on reconnect / catalog refresh).
  Future<int> flushPending() async {
    final items = await queue.list();
    var done = 0;
    for (final item in items) {
      try {
        await _flushItem(item);
        await queue.remove(item.id);
        done += 1;
      } catch (e) {
        log.warn('ingest', 'flush failed for ${item.id}: $e');
        // Keep older items blocked; stop to preserve blob→file→avail order.
        break;
      }
    }
    return done;
  }

  Future<CatalogFile> _flushItem(IngestQueueItem item) async {
    final bytes = await blobs.read(item.hashAlgo, item.contentHash);
    if (bytes == null) {
      throw IngestException(
        'local blob missing for queued ingest ${item.contentHash}',
      );
    }

    final deviceId = await identity.ensureDeviceId();
    await api.putBlob(
      algo: item.hashAlgo,
      hexHash: item.contentHash,
      bytes: bytes,
    );

    final created = await api.createFile(
      FileCreateRequest(
        contentHash: item.contentHash,
        hashAlgo: item.hashAlgo,
        sizeBytes: item.sizeBytes,
        mimeType: item.mimeType,
        title: item.title,
        sourceKind: item.sourceKind,
        sourceDeviceId: deviceId,
        relativePath: item.relativePath,
      ),
    );

    await repository.upsertFile(created);

    final avail = await api.putAvailability(
      fileId: created.fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.pinned.wire,
    );
    await repository.upsertAvailability(
      fileId: created.fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.pinned,
      updatedAt: avail.updatedAt,
    );

    log.info('ingest', 'ingested ${created.fileId} (${item.title ?? item.contentHash})');
    final refreshed = await repository.getFile(created.fileId);
    return refreshed ??
        created.copyWith(
          availabilityMode: AvailabilityMode.pinned,
          hasLocalBytes: true,
        );
  }
}
