import 'dart:convert';

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

  /// Top-level rules with include-regex [TrackingRule.children] attached.
  Future<List<TrackingRule>> listRules() async {
    final rows = await (_db.select(_db.trackingRules)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return _forestFromRows(rows);
  }

  Stream<List<TrackingRule>> watchRules() {
    return (_db.select(_db.trackingRules)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map(_forestFromRows);
  }

  /// Flat list of every rule row (parents and children).
  Future<List<TrackingRule>> listRulesFlat() async {
    final rows = await (_db.select(_db.trackingRules)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return rows.map(_ruleFromRow).toList();
  }

  Future<TrackingRule?> getRule(String id) async {
    final row = await (_db.select(_db.trackingRules)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _ruleFromRow(row);
  }

  Future<TrackingRule> addRule({
    String? name,
    required TrackingRuleKind kind,
    required String patternOrUri,
    bool enabled = true,
    String? parentId,
    List<String> tags = const [],
    String? sourceKind,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final resolvedName = normalizeRuleName(name);
    final cleanedTags = normalizeTagList(tags);
    final cleanedSource = _normalizeSourceKind(sourceKind);

    if (parentId != null) {
      if (kind != TrackingRuleKind.regex) {
        throw ArgumentError('child rules must be regex');
      }
      final parent = await getRule(parentId);
      if (parent == null) {
        throw ArgumentError('parent rule not found: $parentId');
      }
      if (parent.kind != TrackingRuleKind.folder) {
        throw ArgumentError('parent must be a folder rule');
      }
      if (parent.parentId != null) {
        throw ArgumentError('cannot nest under a child rule');
      }
      TrackingPattern.compile(patternOrUri);
    } else if (kind == TrackingRuleKind.regex) {
      TrackingPattern.compile(patternOrUri);
    } else if (kind == TrackingRuleKind.folder ||
        kind == TrackingRuleKind.file) {
      // path validated by picker
    }

    await _db.into(_db.trackingRules).insert(
          TrackingRulesCompanion.insert(
            id: id,
            name: resolvedName,
            kind: kind.wire,
            patternOrUri: patternOrUri.trim(),
            enabled: Value(enabled),
            createdAt: now,
            parentId: Value(parentId),
            tagsJson: Value(encodeTagsJson(cleanedTags)),
            sourceKind: Value(cleanedSource),
          ),
        );
    _log.info(
      'tracking',
      'added rule $resolvedName (${kind.wire}'
      '${parentId != null ? ', child of $parentId' : ''})',
    );
    return TrackingRule(
      id: id,
      name: resolvedName,
      kind: kind,
      patternOrUri: patternOrUri.trim(),
      enabled: enabled,
      createdAt: now,
      parentId: parentId,
      tags: cleanedTags,
      sourceKind: cleanedSource,
    );
  }

  Future<void> updateRule(TrackingRule rule) async {
    if (rule.kind == TrackingRuleKind.regex) {
      TrackingPattern.compile(rule.patternOrUri);
    }
    if (rule.parentId != null) {
      if (rule.kind != TrackingRuleKind.regex) {
        throw ArgumentError('child rules must be regex');
      }
      final parent = await getRule(rule.parentId!);
      if (parent == null || parent.kind != TrackingRuleKind.folder) {
        throw ArgumentError('invalid parent for child rule');
      }
    }
    await (_db.update(_db.trackingRules)..where((t) => t.id.equals(rule.id)))
        .write(
      TrackingRulesCompanion(
        name: Value(normalizeRuleName(rule.name)),
        kind: Value(rule.kind.wire),
        patternOrUri: Value(rule.patternOrUri.trim()),
        enabled: Value(rule.enabled),
        parentId: Value(rule.parentId),
        tagsJson: Value(encodeTagsJson(normalizeTagList(rule.tags))),
        sourceKind: Value(_normalizeSourceKind(rule.sourceKind)),
      ),
    );
  }

  Future<void> deleteRule(String id) async {
    final children = await (_db.select(_db.trackingRules)
          ..where((t) => t.parentId.equals(id)))
        .get();
    for (final child in children) {
      await deleteRule(child.id);
    }
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

  Future<List<LocalTrackedFile>> listLocalFiles({
    String? ruleId,
    Iterable<String>? ruleIds,
  }) async {
    final ids = <String>{
      ?ruleId,
      ...?ruleIds,
    };
    final query = _db.select(_db.localTrackedFiles)
      ..orderBy([(t) => OrderingTerm.desc(t.seenAt)]);
    if (ids.length == 1) {
      query.where((t) => t.ruleId.equals(ids.single));
    } else if (ids.length > 1) {
      query.where((t) => t.ruleId.isIn(ids.toList()));
    }
    final rows = await query.get();
    return rows.map(_localFromRow).toList();
  }

  /// Rule ids for a drawer group: the rule itself plus folder include-children.
  Future<Set<String>> groupRuleIds(String? ruleId) async {
    if (ruleId == null) return {};
    final forest = await listRules();
    for (final r in forest) {
      if (r.id == ruleId) {
        return {r.id, ...r.children.map((c) => c.id)};
      }
    }
    // Child selected directly (unusual) — still return itself.
    return {ruleId};
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
            mtimeMs: Value(file.mtimeMs),
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
    int? sizeBytes,
    int? mtimeMs,
  }) async {
    await (_db.update(_db.localTrackedFiles)
          ..where((t) => t.localPath.equals(localPath)))
        .write(
      LocalTrackedFilesCompanion(
        fileId: Value(fileId),
        contentHash: Value(contentHash),
        sizeBytes: sizeBytes != null ? Value(sizeBytes) : const Value.absent(),
        mtimeMs: mtimeMs != null ? Value(mtimeMs) : const Value.absent(),
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

  List<TrackingRule> _forestFromRows(List<TrackingRuleRow> rows) {
    final flat = rows.map(_ruleFromRow).toList();
    final byParent = <String, List<TrackingRule>>{};
    for (final r in flat) {
      final pid = r.parentId;
      if (pid == null) continue;
      byParent.putIfAbsent(pid, () => []).add(r);
    }
    return [
      for (final r in flat)
        if (r.parentId == null)
          r.copyWith(children: List.unmodifiable(byParent[r.id] ?? const [])),
    ];
  }

  TrackingRule _ruleFromRow(TrackingRuleRow row) {
    return TrackingRule(
      id: row.id,
      name: row.name,
      kind: TrackingRuleKindWire.parse(row.kind),
      patternOrUri: row.patternOrUri,
      enabled: row.enabled,
      createdAt: row.createdAt,
      parentId: row.parentId,
      tags: decodeTagsJson(row.tagsJson),
      sourceKind: row.sourceKind,
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
      mtimeMs: row.mtimeMs,
      mimeType: row.mimeType,
      sourceKind: row.sourceKind,
      seenAt: row.seenAt,
      ingestStatus: IngestStatusWire.parse(row.ingestStatus),
    );
  }
}

List<String> normalizeTagList(Iterable<String> raw) {
  final out = <String>{};
  for (final t in raw) {
    final s = t.trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out.toList()..sort();
}

String encodeTagsJson(List<String> tags) => jsonEncode(normalizeTagList(tags));

List<String> decodeTagsJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return normalizeTagList(decoded.map((e) => '$e'));
  } catch (_) {
    return const [];
  }
}

String? _normalizeSourceKind(String? raw) {
  final t = raw?.trim().toLowerCase();
  if (t == null || t.isEmpty) return null;
  return t;
}
