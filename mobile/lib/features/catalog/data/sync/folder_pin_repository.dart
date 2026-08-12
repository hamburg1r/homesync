import 'package:drift/drift.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

/// CRUD for phone-only folder pin subscriptions.
@lazySingleton
class FolderPinRepository {
  FolderPinRepository(this._db, this._log);

  final CatalogDatabase _db;
  final AppLog _log;
  static const _uuid = Uuid();

  Future<List<FolderPinSubscription>> list({bool enabledOnly = false}) async {
    final query = _db.select(_db.folderPinSubscriptions)
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    if (enabledOnly) {
      query.where((t) => t.enabled.equals(true));
    }
    final rows = await query.get();
    return rows.map(_fromRow).toList();
  }

  Future<FolderPinSubscription?> get(String id) async {
    final row = await (_db.select(_db.folderPinSubscriptions)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<FolderPinSubscription?> findByPrefix(String pathPrefix) async {
    final pfx = normalizeFolderPinPrefix(pathPrefix);
    final row = await (_db.select(_db.folderPinSubscriptions)
          ..where((t) => t.pathPrefix.equals(pfx)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<FolderPinSubscription> add({
    required String name,
    required String pathPrefix,
    required String localRoot,
    bool enabled = true,
  }) async {
    final pfx = normalizeFolderPinPrefix(pathPrefix);
    if (pfx.isEmpty) {
      throw ArgumentError('path prefix must not be empty');
    }
    final root = localRoot.trim();
    if (root.isEmpty) {
      throw ArgumentError('local root must not be empty');
    }
    final existing = await findByPrefix(pfx);
    if (existing != null) {
      final updated = existing.copyWith(
        name: name.trim().isEmpty ? existing.name : name.trim(),
        localRoot: root,
        enabled: enabled,
      );
      await update(updated);
      return updated;
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final display = name.trim().isEmpty ? pfx : name.trim();
    await _db.into(_db.folderPinSubscriptions).insert(
          FolderPinSubscriptionsCompanion.insert(
            id: id,
            name: display,
            pathPrefix: pfx,
            localRoot: root,
            enabled: Value(enabled),
            createdAt: now,
          ),
        );
    _log.info('folder_pin', 'added subscription $display → $pfx @ $root');
    return FolderPinSubscription(
      id: id,
      name: display,
      pathPrefix: pfx,
      localRoot: root,
      enabled: enabled,
      createdAt: now,
    );
  }

  Future<void> update(FolderPinSubscription sub) async {
    final pfx = normalizeFolderPinPrefix(sub.pathPrefix);
    await (_db.update(_db.folderPinSubscriptions)
          ..where((t) => t.id.equals(sub.id)))
        .write(
          FolderPinSubscriptionsCompanion(
            name: Value(sub.name),
            pathPrefix: Value(pfx),
            localRoot: Value(sub.localRoot),
            enabled: Value(sub.enabled),
          ),
        );
  }

  Future<void> setEnabled(String id, {required bool enabled}) async {
    await (_db.update(_db.folderPinSubscriptions)
          ..where((t) => t.id.equals(id)))
        .write(FolderPinSubscriptionsCompanion(enabled: Value(enabled)));
  }

  Future<void> delete(String id) async {
    await (_db.delete(_db.folderPinSubscriptions)
          ..where((t) => t.id.equals(id)))
        .go();
    _log.info('folder_pin', 'deleted subscription $id');
  }

  FolderPinSubscription _fromRow(FolderPinSubscriptionRow row) {
    return FolderPinSubscription(
      id: row.id,
      name: row.name,
      pathPrefix: row.pathPrefix,
      localRoot: row.localRoot,
      enabled: row.enabled,
      createdAt: row.createdAt,
    );
  }
}
