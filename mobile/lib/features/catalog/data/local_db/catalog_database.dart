import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/tables.dart';
import 'package:injectable/injectable.dart';

part 'catalog_database.g.dart';

/// Drift catalog mirror (`homesync_catalog_v2`). Server is SoT for list-only.
@DriftDatabase(
  tables: [CatalogFiles, CatalogTags, CatalogFileTags, SyncMetaEntries],
)
@lazySingleton
class CatalogDatabase extends _$CatalogDatabase {
  CatalogDatabase() : super(_openExecutor());

  CatalogDatabase.forExecutor(super.executor);

  /// In-memory DB for unit tests (no path_provider).
  CatalogDatabase.memory() : super(NativeDatabase.memory());

  static const dbName = 'homesync_catalog_v2';

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openExecutor() {
    return driftDatabase(name: dbName);
  }
}
