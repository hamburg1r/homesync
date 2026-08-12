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

/// Mirrored `file_paths` (provenance for ghost / restore UX).
@DataClassName('CatalogPathRow')
class CatalogPaths extends Table {
  TextColumn get id => text()();
  TextColumn get fileId => text()();
  TextColumn get rootId => text().nullable()();
  TextColumn get relativePath => text()();
  TextColumn get sourceKind => text()();
  TextColumn get sourceDeviceId => text().nullable()();
  BoolColumn get isCurrent => boolean().withDefault(const Constant(true))();
  TextColumn get seenAt => text()();
  TextColumn get goneAt => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
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
  /// `regex` | `folder` | `file`
  TextColumn get kind => text()();
  /// Glob/regex pattern, absolute folder path, or absolute file path.
  TextColumn get patternOrUri => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  /// Parent folder rule id; only set for include-regex children of a folder.
  TextColumn get parentId => text().nullable()();
  /// JSON array of tag names applied on ingest (`[]` when empty).
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  /// Optional `source_kind` override; null keeps path heuristic.
  TextColumn get sourceKind => text().nullable()();
  /// When true, matched files are Bound to server after ingest (PC tombstone
  /// also deletes local pin bytes).
  BoolColumn get bindToServer =>
      boolean().withDefault(const Constant(false))();

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
  /// Last observed mtime (ms since epoch); used to skip rehash when unchanged.
  IntColumn get mtimeMs => integer().nullable()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get sourceKind => text().withDefault(const Constant('misc'))();
  TextColumn get seenAt => text()();
  /// `pending` | `synced` | `failed` | `untracked`
  TextColumn get ingestStatus => text()();

  @override
  Set<Column<Object>> get primaryKey => {localPath};
}

/// Per-file phone policy: when bound, a PC tombstone also deletes local pin bytes.
/// Only meaningful for pinned files (UI enforces that).
@DataClassName('PinServerBindRow')
class PinServerBinds extends Table {
  TextColumn get fileId => text()();
  /// When true, receiving `deleted_at` drops local materialised bytes.
  BoolColumn get deleteOnTombstone =>
      boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {fileId};
}

/// Absolute path where a PC→phone pin was materialised (friendly name / custom dir).
@DataClassName('PinLocalPathRow')
class PinLocalPaths extends Table {
  TextColumn get fileId => text()();
  TextColumn get absolutePath => text()();

  @override
  Set<Column<Object>> get primaryKey => {fileId};
}

/// Last-seen directory mtime for incremental phone tracking scans.
@DataClassName('ScanDirCacheRow')
class ScanDirCache extends Table {
  TextColumn get dirPath => text()();
  IntColumn get mtimeMs => integer()();

  @override
  Set<Column<Object>> get primaryKey => {dirPath};
}

/// Phone-only: auto-pin catalog files under a relative_path prefix (PC→phone).
@DataClassName('FolderPinSubscriptionRow')
class FolderPinSubscriptions extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  /// Catalog `file_paths.relative_path` prefix (directory boundary).
  TextColumn get pathPrefix => text()();
  /// Absolute phone directory that mirrors the tree under [pathPrefix].
  TextColumn get localRoot => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
