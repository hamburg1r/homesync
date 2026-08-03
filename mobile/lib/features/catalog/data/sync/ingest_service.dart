import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;

class IngestException implements Exception {
  IngestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Progress for a single ingest (hash → upload → local pin).
class IngestFileProgress {
  const IngestFileProgress({
    required this.title,
    required this.index,
    required this.total,
    required this.phase,
    required this.fraction,
  });

  final String title;
  /// 1-based index among the current batch.
  final int index;
  final int total;
  /// `scanning` | `preparing` | `hashing` | `uploading` | `storing` | `finishing`
  final String phase;
  /// 0.0–1.0 within [phase].
  final double fraction;

  /// True when [overall] is meaningful for a determinate progress bar.
  bool get determinate =>
      phase != 'scanning' && phase != 'preparing' && total > 0;

  /// Human-readable phase for banners / notifications.
  String get phaseLabel => switch (phase) {
        'scanning' => 'Scanning',
        'preparing' => 'Preparing',
        'hashing' => 'Hashing',
        'uploading' => 'Uploading',
        'storing' => 'Storing',
        'finishing' => 'Finishing',
        _ => phase,
      };

  /// Single 0–1 value for UI (hash 0–0.4, upload 0.4–0.95, finish 0.95–1).
  double get overall {
    final f = fraction.clamp(0.0, 1.0);
    return switch (phase) {
      'scanning' || 'preparing' => 0,
      'hashing' => f * 0.4,
      'uploading' => 0.4 + f * 0.55,
      _ => 0.95 + f * 0.05,
    };
  }
}

typedef IngestProgressCallback = void Function(IngestFileProgress progress);

/// Phone → PC ingest: hash → queue → streamed PUT → POST file → pin.
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

  /// Ingest in-memory bytes (small payloads / tests).
  Future<CatalogFile> ingestBytes(
    Uint8List bytes, {
    String? title,
    String? mimeType,
    String sourceKind = 'misc',
    String? relativePath,
    IngestProgressCallback? onProgress,
  }) async {
    final display = title ?? 'upload';
    onProgress?.call(
      IngestFileProgress(
        title: display,
        index: 1,
        total: 1,
        phase: 'hashing',
        fraction: 1,
      ),
    );
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
      final file = await _flushItem(
        item,
        onProgress: onProgress,
        index: 1,
        total: 1,
      );
      await queue.remove(item.id);
      return file;
    } catch (e) {
      log.warn('ingest', 'queued for retry after failure: $e');
      rethrow;
    }
  }

  /// Hash + enqueue only (no upload). Used before FG task-isolate HTTP.
  ///
  /// When [knownContentHash] is set (mtime/size gate already matched), skips
  /// blake3 and enqueues that digest.
  Future<IngestQueueItem> enqueueFile(
    File source, {
    String? title,
    String? mimeType,
    String sourceKind = 'misc',
    String? relativePath,
    String? replaceFileId,
    String? knownContentHash,
    int index = 1,
    int total = 1,
    IngestProgressCallback? onProgress,
  }) async {
    if (!await source.exists()) {
      throw IngestException('file missing: ${source.path}');
    }
    final display = title ?? p.basename(source.path);
    final size = await source.length();

    final String hash;
    final known = knownContentHash?.trim();
    if (known != null && known.isNotEmpty) {
      onProgress?.call(
        IngestFileProgress(
          title: display,
          index: index,
          total: total,
          phase: 'hashing',
          fraction: 1,
        ),
      );
      hash = known;
    } else {
      hash = await ContentHash.blake3File(
        source,
        onProgress: (done, totalBytes) {
          onProgress?.call(
            IngestFileProgress(
              title: display,
              index: index,
              total: total,
              phase: 'hashing',
              fraction: totalBytes == 0 ? 1 : done / totalBytes,
            ),
          );
        },
      );
    }

    final item = IngestQueue.newItem(
      contentHash: hash,
      hashAlgo: ContentHash.algo,
      sizeBytes: size,
      mimeType: mimeType,
      title: display,
      sourceKind: sourceKind,
      relativePath: relativePath,
      sourcePath: source.path,
      replaceFileId: replaceFileId,
    );
    await queue.enqueue(item);
    return item;
  }

  /// Stream-hash + upload one file without loading it fully into RAM.
  ///
  /// When [replaceFileId] is set, uploads then ``POST …/content`` to keep the
  /// same logical id. If [previousContentHash] matches the new digest, skips
  /// the network and returns the local catalog row.
  Future<CatalogFile> ingestFile(
    File source, {
    String? title,
    String? mimeType,
    String sourceKind = 'misc',
    String? relativePath,
    String? replaceFileId,
    String? previousContentHash,
    String? knownContentHash,
    int index = 1,
    int total = 1,
    IngestProgressCallback? onProgress,
  }) async {
    final item = await enqueueFile(
      source,
      title: title,
      mimeType: mimeType,
      sourceKind: sourceKind,
      relativePath: relativePath,
      replaceFileId: replaceFileId,
      knownContentHash: knownContentHash,
      index: index,
      total: total,
      onProgress: onProgress,
    );

    if (replaceFileId != null &&
        item.contentHash ==
            (previousContentHash ??
                (await repository.getFile(replaceFileId))?.contentHash)) {
      await queue.remove(item.id);
      final existing = await repository.getFile(replaceFileId);
      if (existing != null) {
        return existing.copyWith(
          availabilityMode: AvailabilityMode.pinned,
          hasLocalBytes: true,
        );
      }
      // Local catalog lag — still no network needed for identical bytes.
      return CatalogFile(
        fileId: replaceFileId,
        contentHash: item.contentHash,
        hashAlgo: item.hashAlgo,
        mimeType: item.mimeType,
        sizeBytes: item.sizeBytes,
        title: item.title,
        notes: null,
        takenAt: null,
        createdAt: item.createdAt,
        updatedAt: item.createdAt,
        deletedAt: null,
        tags: const [],
        availabilityMode: AvailabilityMode.pinned,
        hasLocalBytes: true,
      );
    }

    try {
      final file = await _flushItem(
        item,
        onProgress: onProgress,
        index: index,
        total: total,
      );
      await queue.remove(item.id);
      return file;
    } catch (e) {
      log.warn('ingest', 'queued for retry after failure: $e');
      rethrow;
    }
  }

  /// Apply PC responses after HTTP ran in another isolate (no second upload).
  Future<CatalogFile> commitRemoteIngest({
    required IngestQueueItem item,
    required CatalogFile created,
    required AvailabilityInfo availability,
  }) async {
    await repository.upsertFile(created);
    await repository.upsertAvailability(
      fileId: created.fileId,
      deviceId: availability.deviceId,
      mode: AvailabilityMode.parse(availability.mode),
      updatedAt: availability.updatedAt,
    );
    await queue.remove(item.id);
    final refreshed = await repository.getFile(created.fileId);
    final onDevice = await blobs.has(item.hashAlgo, item.contentHash) ||
        (item.sourcePath != null && await File(item.sourcePath!).exists());
    return (refreshed ?? created).copyWith(
      availabilityMode: AvailabilityMode.pinned,
      hasLocalBytes: onDevice,
    );
  }

  /// Flush any durable queue items (call on reconnect / catalog refresh).
  Future<int> flushPending({IngestProgressCallback? onProgress}) async {
    final items = await queue.list();
    var done = 0;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      try {
        await _flushItem(
          item,
          onProgress: onProgress,
          index: i + 1,
          total: items.length,
        );
        await queue.remove(item.id);
        done += 1;
      } catch (e) {
        log.warn('ingest', 'flush failed for ${item.id}: $e');
        break;
      }
    }
    return done;
  }

  Future<CatalogFile> _flushItem(
    IngestQueueItem item, {
    IngestProgressCallback? onProgress,
    int index = 1,
    int total = 1,
  }) async {
    final display = item.title ?? item.contentHash;
    final sourceFile =
        item.sourcePath != null ? File(item.sourcePath!) : null;
    final hasPin = await blobs.has(item.hashAlgo, item.contentHash);
    final sourceOk = sourceFile != null && await sourceFile.exists();
    if (!hasPin && !sourceOk) {
      throw IngestException(
        'local blob missing for queued ingest ${item.contentHash}',
      );
    }

    final deviceId = await identity.ensureDeviceId();
    final File bytesFile;
    if (sourceFile != null && await sourceFile.exists()) {
      bytesFile = sourceFile;
    } else {
      bytesFile = await blobs.pathFor(item.hashAlgo, item.contentHash);
    }

    await api.putBlobResumable(
      algo: item.hashAlgo,
      hexHash: item.contentHash,
      contentLength: item.sizeBytes,
      readAt: (offset, length) async {
        final raf = await bytesFile.open();
        try {
          await raf.setPosition(offset);
          return await raf.read(length);
        } finally {
          await raf.close();
        }
      },
      onProgress: (sent, totalBytes) {
        onProgress?.call(
          IngestFileProgress(
            title: display,
            index: index,
            total: total,
            phase: 'uploading',
            fraction: totalBytes == 0 ? 1 : sent / totalBytes,
          ),
        );
      },
    );

    // Phone↔PC: keep the original path as the on-device copy.
    // Do not duplicate into app pin storage when uploading from sourcePath.
    // (Pin store is only for PC→phone materialization / small ingestBytes.)

    onProgress?.call(
      IngestFileProgress(
        title: display,
        index: index,
        total: total,
        phase: 'finishing',
        fraction: 0.5,
      ),
    );

    late final CatalogFile created;
    try {
      created = item.replaceFileId != null
          ? await api.updateFileContent(
              item.replaceFileId!,
              FileContentRequest(
                contentHash: item.contentHash,
                hashAlgo: item.hashAlgo,
                sizeBytes: item.sizeBytes,
                note: 'phone track',
              ),
            )
          : await api.createFile(
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
    } on KdbxConflictPendingException {
      log.warn(
        'ingest',
        'KeePass conflict outbox for ${item.replaceFileId} '
        '(local hash ${item.contentHash})',
      );
      rethrow;
    }

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

    onProgress?.call(
      IngestFileProgress(
        title: display,
        index: index,
        total: total,
        phase: 'finishing',
        fraction: 1,
      ),
    );

    log.info(
      'ingest',
      'ingested ${created.fileId} (${item.title ?? item.contentHash})',
    );
    final refreshed = await repository.getFile(created.fileId);
    final onDevice = hasPin || sourceOk || await blobs.has(item.hashAlgo, item.contentHash);
    return (refreshed ?? created).copyWith(
      availabilityMode: AvailabilityMode.pinned,
      hasLocalBytes: onDevice,
    );
  }
}
