import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/tables.dart';
import 'package:injectable/injectable.dart';

part 'catalog_database.g.dart';

/// Drift catalog mirror (`homesync_catalog_v2`). Server is SoT for list-only.
@DriftDatabase(
  tables: [
    CatalogFiles,
    CatalogTags,
    CatalogFileTags,
    CatalogAvailability,
    CatalogPaths,
    SyncMetaEntries,
    TrackingRules,
    LocalTrackedFiles,
    PinServerBinds,
    PinLocalPaths,
  ],
)
@lazySingleton
class CatalogDatabase extends _$CatalogDatabase {
  CatalogDatabase() : super(_openExecutor());

  CatalogDatabase.forExecutor(super.executor);

  /// In-memory DB for unit tests (no path_provider).
  CatalogDatabase.memory() : super(NativeDatabase.memory());

  static const dbName = 'homesync_catalog_v2';

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(catalogAvailability);
          }
          if (from < 3) {
            await m.createTable(trackingRules);
            await m.createTable(localTrackedFiles);
          }
          if (from < 4) {
            await m.createTable(catalogPaths);
          }
          if (from < 5) {
            await m.createTable(pinServerBinds);
          }
          if (from < 6) {
            await m.createTable(pinLocalPaths);
          }
          if (from < 7) {
            await m.addColumn(localTrackedFiles, localTrackedFiles.mtimeMs);
          }
        },
      );

  static QueryExecutor _openExecutor() {
    return driftDatabase(name: dbName);
  }
}
