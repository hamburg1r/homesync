import 'package:drift/drift.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:injectable/injectable.dart';

/// Catalog mirror access for sync + UI (hides Drift details).
@lazySingleton
class CatalogRepository {
  CatalogRepository(this._db, this._log);

  final CatalogDatabase _db;
  final AppLog _log;

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
      'cursor=${delta.nextCursor.isEmpty ? "(unchanged)" : delta.nextCursor}',
    );
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
    final result = <CatalogFile>[];
    for (final row in rows) {
      final tags = await _tagNamesFor(row.fileId);
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
        ),
      );
    }
    return result;
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
