import 'package:drift/drift.dart';

/// Local mirror of server `files` (list-only; no blob bytes).
@DataClassName('CatalogFileRow')
class CatalogFiles extends Table {
  TextColumn get fileId => text()();
  TextColumn get contentHash => text()();
  TextColumn get hashAlgo => text()();
  TextColumn get mimeType => text().nullable()();
  IntColumn get sizeBytes => integer()();
  TextColumn get title => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get takenAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {fileId};
}

@DataClassName('CatalogTagRow')
class CatalogTags extends Table {
  TextColumn get tagId => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {tagId};
}

@DataClassName('CatalogFileTagRow')
class CatalogFileTags extends Table {
  TextColumn get fileId => text()();
  TextColumn get tagId => text()();

  @override
  Set<Column<Object>> get primaryKey => {fileId, tagId};
}

@DataClassName('SyncMetaRow')
class SyncMetaEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
