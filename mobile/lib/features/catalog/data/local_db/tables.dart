import 'package:drift/drift.dart';

/// Local mirror of server `files` (list-only metadata; bytes live on disk).
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

/// Per-device availability for this phone (`listed` / `cached` / `pinned`).
@DataClassName('CatalogAvailabilityRow')
class CatalogAvailability extends Table {
  TextColumn get fileId => text()();
  TextColumn get deviceId => text()();
  TextColumn get mode => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {fileId, deviceId};
}

@DataClassName('SyncMetaRow')
class SyncMetaEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// User-configured tracking rule (regex pattern or folder). Group name for drawer.
@DataClassName('TrackingRuleRow')
class TrackingRules extends Table {
  TextColumn get id => text()();
  /// Display / drawer group name; defaults to `misc` when blank at insert time.
  TextColumn get name => text()();
  /// `regex` | `folder`
  TextColumn get kind => text()();
  /// Glob/regex pattern, or absolute folder path / SAF URI.
  TextColumn get patternOrUri => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Device file discovered by a scan (tracked if [ruleId] set).
@DataClassName('LocalTrackedFileRow')
class LocalTrackedFiles extends Table {
  TextColumn get localPath => text()();
  TextColumn get ruleId => text().nullable()();
  TextColumn get fileId => text().nullable()();
  TextColumn get contentHash => text().nullable()();
  TextColumn get title => text().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get mimeType => text().nullable()();
  TextColumn get sourceKind => text().withDefault(const Constant('misc'))();
  TextColumn get seenAt => text()();
  /// `pending` | `synced` | `failed` | `untracked`
  TextColumn get ingestStatus => text()();

  @override
  Set<Column<Object>> get primaryKey => {localPath};
}
