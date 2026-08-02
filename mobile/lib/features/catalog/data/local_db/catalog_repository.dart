import 'dart:io';

import 'package:drift/drift.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:injectable/injectable.dart';

/// Catalog mirror access for sync + UI (hides Drift details).
@lazySingleton
class CatalogRepository {
  CatalogRepository(
    this._db,
    this._log,
    this._blobs,
    this._identity,
  );

  final CatalogDatabase _db;
  final AppLog _log;
  final LocalBlobStore _blobs;
  final DeviceIdentity _identity;

  CatalogDatabase get database => _db;

  Future<void> close() => _db.close();

  Future<String?> getDeltaCursor() async {
    final row = await (_db.select(_db.syncMetaEntries)
          ..where((t) => t.key.equals(_deltaCursorKey)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setDeltaCursor(String cursor) async {
    await _db
        .into(_db.syncMetaEntries)
        .insertOnConflictUpdate(
          SyncMetaEntriesCompanion.insert(key: _deltaCursorKey, value: cursor),
        );
  }

  Future<void> applyDelta(CatalogDelta delta) async {
    final deviceId = await _identity.ensureDeviceId();
    await _db.transaction(() async {
      for (final tag in delta.tags) {
        await _db
            .into(_db.catalogTags)
            .insertOnConflictUpdate(
              CatalogTagsCompanion.insert(
                tagId: tag.tagId,
                name: tag.name,
                color: Value(tag.color),
              ),
            );
      }

      for (final file in delta.files) {
        await _db
            .into(_db.catalogFiles)
            .insertOnConflictUpdate(
              CatalogFilesCompanion.insert(
                fileId: file.fileId,
                contentHash: file.contentHash,
                hashAlgo: file.hashAlgo,
                mimeType: Value(file.mimeType),
                sizeBytes: file.sizeBytes,
                title: Value(file.title),
                notes: Value(file.notes),
                takenAt: Value(file.takenAt),
                createdAt: file.createdAt,
                updatedAt: file.updatedAt,
                deletedAt: Value(file.deletedAt),
              ),
            );
        await (_db.delete(_db.catalogFileTags)
              ..where((t) => t.fileId.equals(file.fileId)))
            .go();

        // Tombstone: drop local pin bytes only when bound to server.
        if (file.deletedAt != null) {
          final bound = await _isBoundToServer(file.fileId);
          if (bound) {
            await clearPinLocalPath(file.fileId);
            await _deleteBlobIfUnreferenced(
              algo: file.hashAlgo,
              contentHash: file.contentHash,
              exceptFileId: file.fileId,
            );
          }
          await clearBoundToServer(file.fileId);
        }

        // Default remote files to listed for this device unless server sent a row.
        final existing = await (_db.select(_db.catalogAvailability)
              ..where(
                (a) =>
                    a.fileId.equals(file.fileId) & a.deviceId.equals(deviceId),
              ))
            .getSingleOrNull();
        if (existing == null) {
          await _db.into(_db.catalogAvailability).insert(
                CatalogAvailabilityCompanion.insert(
                  fileId: file.fileId,
                  deviceId: deviceId,
                  mode: AvailabilityMode.listed.wire,
                  updatedAt: file.updatedAt,
                ),
              );
        }
      }

      for (final ft in delta.fileTags) {
        await _db
            .into(_db.catalogFileTags)
            .insertOnConflictUpdate(
              CatalogFileTagsCompanion.insert(
                fileId: ft.fileId,
                tagId: ft.tagId,
              ),
            );
      }

      // Replace mirrored paths for files in this page (provenance).
      final pathFileIds = {
        ...delta.paths.map((p) => p.fileId),
        ...delta.files.map((f) => f.fileId),
      };
      for (final fileId in pathFileIds) {
        await (_db.delete(_db.catalogPaths)
              ..where((t) => t.fileId.equals(fileId)))
            .go();
      }
      for (final path in delta.paths) {
        await _db.into(_db.catalogPaths).insert(
              CatalogPathsCompanion.insert(
                id: path.id,
                fileId: path.fileId,
                rootId: Value(path.rootId),
                relativePath: path.relativePath,
                sourceKind: path.sourceKind,
                sourceDeviceId: Value(path.sourceDeviceId),
                isCurrent: Value(path.isCurrent),
                seenAt: path.seenAt,
                goneAt: Value(path.goneAt),
              ),
            );
      }

      for (final avail in delta.availability) {
        // Only persist this phone's availability locally.
        if (avail.deviceId != deviceId) continue;
        await _db
            .into(_db.catalogAvailability)
            .insertOnConflictUpdate(
              CatalogAvailabilityCompanion.insert(
                fileId: avail.fileId,
                deviceId: avail.deviceId,
                mode: AvailabilityMode.parse(avail.mode).wire,
                updatedAt: avail.updatedAt,
              ),
            );
      }

      if (delta.nextCursor.isNotEmpty) {
        await _db
            .into(_db.syncMetaEntries)
            .insertOnConflictUpdate(
              SyncMetaEntriesCompanion.insert(
                key: _deltaCursorKey,
                value: delta.nextCursor,
              ),
            );
      }
    });
    _log.info(
      'catalog',
      'applyDelta files=${delta.files.length} tags=${delta.tags.length} '
      'paths=${delta.paths.length} availability=${delta.availability.length} '
      'cursor=${delta.nextCursor.isEmpty ? "(unchanged)" : delta.nextCursor}',
    );
  }

  Future<void> upsertAvailability({
    required String fileId,
    required String deviceId,
    required AvailabilityMode mode,
    required String updatedAt,
  }) async {
    await _db
        .into(_db.catalogAvailability)
        .insertOnConflictUpdate(
          CatalogAvailabilityCompanion.insert(
            fileId: fileId,
            deviceId: deviceId,
            mode: mode.wire,
            updatedAt: updatedAt,
          ),
        );
  }

  /// Upsert a single catalog file row (e.g. after phone ingest).
  Future<void> upsertFile(CatalogFile file) async {
    await _db.transaction(() async {
      await _db.into(_db.catalogFiles).insertOnConflictUpdate(
            CatalogFilesCompanion.insert(
              fileId: file.fileId,
              contentHash: file.contentHash,
              hashAlgo: file.hashAlgo,
              mimeType: Value(file.mimeType),
              sizeBytes: file.sizeBytes,
              title: Value(file.title),
              notes: Value(file.notes),
              takenAt: Value(file.takenAt),
              createdAt: file.createdAt,
              updatedAt: file.updatedAt,
              deletedAt: Value(file.deletedAt),
            ),
          );
    });
  }

  /// Apply a soft-delete tombstone locally (after `DELETE /v1/files/{id}`).
  /// Explicit phone-initiated remove always drops local bytes.
  Future<void> applyTombstone(CatalogFile file) async {
    await upsertFile(file);
    if (file.deletedAt != null) {
      await clearPinLocalPath(file.fileId);
      await _deleteBlobIfUnreferenced(
        algo: file.hashAlgo,
        contentHash: file.contentHash,
        exceptFileId: file.fileId,
      );
      await clearBoundToServer(file.fileId);
    }
  }

  /// Opt-in: PC tombstone also deletes this pin's local bytes.
  Future<void> setBoundToServer(String fileId, {required bool bound}) async {
    if (!bound) {
      await clearBoundToServer(fileId);
      return;
    }
    await _db.into(_db.pinServerBinds).insertOnConflictUpdate(
          PinServerBindsCompanion.insert(
            fileId: fileId,
            deleteOnTombstone: const Value(true),
          ),
        );
    _log.info('catalog', 'bound to server $fileId');
  }

  Future<void> clearBoundToServer(String fileId) async {
    await (_db.delete(_db.pinServerBinds)
          ..where((t) => t.fileId.equals(fileId)))
        .go();
  }

  Future<String?> pinLocalPathForFileId(String fileId) async {
    final row = await (_db.select(_db.pinLocalPaths)
          ..where((t) => t.fileId.equals(fileId)))
        .getSingleOrNull();
    return row?.absolutePath;
  }

  Future<void> setPinLocalPath(String fileId, String absolutePath) async {
    await _db.into(_db.pinLocalPaths).insertOnConflictUpdate(
          PinLocalPathsCompanion.insert(
            fileId: fileId,
            absolutePath: absolutePath,
          ),
        );
  }

  /// Delete the materialised file on disk (if any) and clear the mapping.
  Future<void> clearPinLocalPath(
    String fileId, {
    bool deleteFile = true,
  }) async {
    final path = await pinLocalPathForFileId(fileId);
    if (deleteFile && path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        _log.info('catalog', 'deleted pin local path $path');
      }
    }
    await (_db.delete(_db.pinLocalPaths)
          ..where((t) => t.fileId.equals(fileId)))
        .go();
  }

  Future<bool> _isBoundToServer(String fileId) async {
    final row = await (_db.select(_db.pinServerBinds)
          ..where((t) => t.fileId.equals(fileId)))
        .getSingleOrNull();
    return row?.deleteOnTombstone ?? false;
  }

  /// Absolute path of a phone-origin file (tracking), if still on disk.
  Future<String?> originPathForFileId(String fileId) async {
    final row = await (_db.select(_db.localTrackedFiles)
          ..where((t) => t.fileId.equals(fileId)))
        .getSingleOrNull();
    return row?.localPath;
  }

  /// Best catalog relative path for display (provenance), if mirrored.
  Future<String?> primaryRelativePath(String fileId) async {
    final path = await _primaryPathRow(fileId);
    return path?.relativePath;
  }

  Future<CatalogPathRow?> _primaryPathRow(String fileId) async {
    final paths = await (_db.select(_db.catalogPaths)
          ..where((p) => p.fileId.equals(fileId)))
        .get();
    if (paths.isEmpty) return null;

    int rank(CatalogPathRow p) {
      var score = 0;
      if (p.isCurrent && p.goneAt == null) score += 100;
      score += switch (p.sourceKind.toLowerCase()) {
        'whatsapp' => 50,
        'camera' => 40,
        'download' => 30,
        'misc' => 20,
        'manual' => 10,
        _ => 0,
      };
      return score;
    }

    paths.sort((a, b) => rank(b).compareTo(rank(a)));
    return paths.first;
  }

  Future<CatalogFile?> getFile(String fileId) async {
    final row = await (_db.select(_db.catalogFiles)
          ..where((f) => f.fileId.equals(fileId)))
        .getSingleOrNull();
    if (row == null) return null;
    final mapped = await _mapFilesWithTags([row]);
    return mapped.first;
  }

  Future<List<CatalogFile>> listActiveFiles() async {
    final rows = await (_db.select(_db.catalogFiles)
          ..where((f) => f.deletedAt.isNull())
          ..orderBy([
            (f) => OrderingTerm.desc(f.updatedAt),
            (f) => OrderingTerm.desc(f.fileId),
          ]))
        .get();
    return _mapFilesWithTags(rows);
  }

  Stream<List<CatalogFile>> watchActiveFiles() {
    final query = _db.select(_db.catalogFiles)
      ..where((f) => f.deletedAt.isNull())
      ..orderBy([
        (f) => OrderingTerm.desc(f.updatedAt),
        (f) => OrderingTerm.desc(f.fileId),
      ]);
    return query.watch().asyncMap(_mapFilesWithTags);
  }

  Future<List<CatalogFile>> _mapFilesWithTags(List<CatalogFileRow> rows) async {
    final deviceId = await _identity.ensureDeviceId();
    final result = <CatalogFile>[];
    for (final row in rows) {
      final tags = await _tagNamesFor(row.fileId);
      final avail = await (_db.select(_db.catalogAvailability)
            ..where(
              (a) =>
                  a.fileId.equals(row.fileId) & a.deviceId.equals(deviceId),
            ))
          .getSingleOrNull();
      final mode = AvailabilityMode.parse(avail?.mode ?? 'listed');
      final hasPin = await _blobs.has(row.hashAlgo, row.contentHash);
      final origin = await originPathForFileId(row.fileId);
      final hasOrigin = origin != null && await File(origin).exists();
      final pinLocal = await pinLocalPathForFileId(row.fileId);
      final hasPinLocal = pinLocal != null && await File(pinLocal).exists();
      final sourceKind = await _primarySourceKind(row.fileId);
      final bound = await _isBoundToServer(row.fileId);
      result.add(
        CatalogFile(
          fileId: row.fileId,
          contentHash: row.contentHash,
          hashAlgo: row.hashAlgo,
          mimeType: row.mimeType,
          sizeBytes: row.sizeBytes,
          title: row.title,
          notes: row.notes,
          takenAt: row.takenAt,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          tags: tags,
          availabilityMode: mode,
          hasLocalBytes: hasPin || hasOrigin || hasPinLocal,
          primarySourceKind: sourceKind,
          boundToServer: bound,
        ),
      );
    }
    return result;
  }

  /// Prefer current / known provenance for ghost restore labels.
  Future<String?> _primarySourceKind(String fileId) async {
    final path = await _primaryPathRow(fileId);
    if (path == null) return null;
    final kind = path.sourceKind.trim().toLowerCase();
    if (kind.isEmpty || kind == 'unknown') return null;
    return kind;
  }

  Future<void> _deleteBlobIfUnreferenced({
    required String algo,
    required String contentHash,
    required String exceptFileId,
  }) async {
    final others = await (_db.select(_db.catalogFiles)
          ..where(
            (f) =>
                f.contentHash.equals(contentHash) &
                f.hashAlgo.equals(algo) &
                f.deletedAt.isNull() &
                f.fileId.isNotValue(exceptFileId),
          ))
        .get();
    if (others.isEmpty) {
      await _blobs.delete(algo, contentHash);
    }
  }

  Future<List<String>> _tagNamesFor(String fileId) async {
    final query = _db.select(_db.catalogTags).join([
      innerJoin(
        _db.catalogFileTags,
        _db.catalogFileTags.tagId.equalsExp(_db.catalogTags.tagId),
      ),
    ])
      ..where(_db.catalogFileTags.fileId.equals(fileId))
      ..orderBy([OrderingTerm.asc(_db.catalogTags.name)]);
    final rows = await query.get();
    return rows.map((r) => r.readTable(_db.catalogTags).name).toList();
  }

  static const _deltaCursorKey = 'delta_cursor';
}
