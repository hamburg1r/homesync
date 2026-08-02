import 'package:drift/drift.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_pattern.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

@lazySingleton
class TrackingRepository {
  TrackingRepository(this._db, this._log);

  final CatalogDatabase _db;
  final AppLog _log;

  Future<List<TrackingRule>> listRules() async {
    final rows = await (_db.select(_db.trackingRules)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return rows.map(_ruleFromRow).toList();
  }

  Stream<List<TrackingRule>> watchRules() {
    return (_db.select(_db.trackingRules)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_ruleFromRow).toList());
  }

  Future<TrackingRule> addRule({
    String? name,
    required TrackingRuleKind kind,
    required String patternOrUri,
    bool enabled = true,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final resolvedName = normalizeRuleName(name);
    if (kind == TrackingRuleKind.regex) {
      TrackingPattern.compile(patternOrUri); // validate early
    }
    await _db.into(_db.trackingRules).insert(
          TrackingRulesCompanion.insert(
            id: id,
            name: resolvedName,
            kind: kind.wire,
            patternOrUri: patternOrUri.trim(),
            enabled: Value(enabled),
            createdAt: now,
          ),
        );
    _log.info('tracking', 'added rule $resolvedName (${kind.wire})');
    return TrackingRule(
      id: id,
      name: resolvedName,
      kind: kind,
      patternOrUri: patternOrUri.trim(),
      enabled: enabled,
      createdAt: now,
    );
  }

  Future<void> updateRule(TrackingRule rule) async {
    if (rule.kind == TrackingRuleKind.regex) {
      TrackingPattern.compile(rule.patternOrUri);
    }
    await (_db.update(_db.trackingRules)..where((t) => t.id.equals(rule.id)))
        .write(
      TrackingRulesCompanion(
        name: Value(normalizeRuleName(rule.name)),
        kind: Value(rule.kind.wire),
        patternOrUri: Value(rule.patternOrUri.trim()),
        enabled: Value(rule.enabled),
      ),
    );
  }

  Future<void> deleteRule(String id) async {
    await (_db.delete(_db.trackingRules)..where((t) => t.id.equals(id))).go();
    await (_db.update(_db.localTrackedFiles)
          ..where((t) => t.ruleId.equals(id)))
        .write(const LocalTrackedFilesCompanion(ruleId: Value(null)));
  }

  Future<void> setRuleEnabled(String id, bool enabled) async {
    await (_db.update(_db.trackingRules)..where((t) => t.id.equals(id))).write(
      TrackingRulesCompanion(enabled: Value(enabled)),
    );
  }

  Future<LocalTrackedFile?> getLocalFile(String localPath) async {
    final row = await (_db.select(_db.localTrackedFiles)
          ..where((t) => t.localPath.equals(localPath)))
        .getSingleOrNull();
    return row == null ? null : _localFromRow(row);
  }

  Future<List<LocalTrackedFile>> listLocalFiles({String? ruleId}) async {
    final query = _db.select(_db.localTrackedFiles)
      ..orderBy([(t) => OrderingTerm.desc(t.seenAt)]);
    if (ruleId != null) {
      query.where((t) => t.ruleId.equals(ruleId));
    }
    final rows = await query.get();
    return rows.map(_localFromRow).toList();
  }

  Future<List<LocalTrackedFile>> listTracked() async {
    final rows = await (_db.select(_db.localTrackedFiles)
          ..where((t) => t.ruleId.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.seenAt)]))
        .get();
    return rows.map(_localFromRow).toList();
  }

  /// Pending or failed tracked files waiting for phone→PC ingest.
  Future<List<LocalTrackedFile>> listNeedingIngest() async {
    final rows = await (_db.select(_db.localTrackedFiles)
          ..where(
            (t) =>
                t.ruleId.isNotNull() &
                t.ingestStatus.isIn([
                  IngestStatus.pending.wire,
                  IngestStatus.failed.wire,
                ]),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.seenAt)]))
        .get();
    return rows.map(_localFromRow).toList();
  }

  Future<List<LocalTrackedFile>> listUntracked() async {
    final rows = await (_db.select(_db.localTrackedFiles)
          ..where((t) => t.ruleId.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.seenAt)]))
        .get();
    return rows.map(_localFromRow).toList();
  }

  Stream<List<LocalTrackedFile>> watchLocalFiles() {
    return (_db.select(_db.localTrackedFiles)
          ..orderBy([(t) => OrderingTerm.desc(t.seenAt)]))
        .watch()
        .map((rows) => rows.map(_localFromRow).toList());
  }

  Future<void> upsertLocalFile(LocalTrackedFile file) async {
    await _db.into(_db.localTrackedFiles).insertOnConflictUpdate(
          LocalTrackedFilesCompanion.insert(
            localPath: file.localPath,
            ruleId: Value(file.ruleId),
            fileId: Value(file.fileId),
            contentHash: Value(file.contentHash),
            title: Value(file.title),
            sizeBytes: Value(file.sizeBytes),
            mimeType: Value(file.mimeType),
            sourceKind: Value(file.sourceKind),
            seenAt: file.seenAt,
            ingestStatus: file.ingestStatus.wire,
          ),
        );
  }

  Future<void> markSynced({
    required String localPath,
    required String fileId,
    required String contentHash,
  }) async {
    await (_db.update(_db.localTrackedFiles)
          ..where((t) => t.localPath.equals(localPath)))
        .write(
      LocalTrackedFilesCompanion(
        fileId: Value(fileId),
        contentHash: Value(contentHash),
        ingestStatus: Value(IngestStatus.synced.wire),
      ),
    );
  }

  Future<void> markFailed(String localPath) async {
    await (_db.update(_db.localTrackedFiles)
          ..where((t) => t.localPath.equals(localPath)))
        .write(
      LocalTrackedFilesCompanion(
        ingestStatus: Value(IngestStatus.failed.wire),
      ),
    );
  }

  Future<void> clearScanResults() async {
    await _db.delete(_db.localTrackedFiles).go();
  }

  TrackingRule _ruleFromRow(TrackingRuleRow row) {
    return TrackingRule(
      id: row.id,
      name: row.name,
      kind: TrackingRuleKindWire.parse(row.kind),
      patternOrUri: row.patternOrUri,
      enabled: row.enabled,
      createdAt: row.createdAt,
    );
  }

  LocalTrackedFile _localFromRow(LocalTrackedFileRow row) {
    return LocalTrackedFile(
      localPath: row.localPath,
      ruleId: row.ruleId,
      fileId: row.fileId,
      contentHash: row.contentHash,
      title: row.title,
      sizeBytes: row.sizeBytes,
      mimeType: row.mimeType,
      sourceKind: row.sourceKind,
      seenAt: row.seenAt,
      ingestStatus: IngestStatusWire.parse(row.ingestStatus),
    );
  }
}
