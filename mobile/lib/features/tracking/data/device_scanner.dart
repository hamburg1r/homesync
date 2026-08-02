import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/tracking/data/source_kind.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_pattern.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

/// Walk reachable storage roots, classify against rules, ingest matches.
@lazySingleton
class DeviceScanner {
  DeviceScanner({
    required this.repository,
    required this.ingest,
    required this.log,
    List<Directory>? scanRoots,
  }) : _scanRootsOverride = scanRoots;

  final TrackingRepository repository;
  final IngestService ingest;
  final AppLog log;
  final List<Directory>? _scanRootsOverride;

  /// Discover files, update local index, ingest pending tracked files.
  Future<ScanResult> scanAndIngest({bool ingestMatches = true}) async {
    final rules = (await repository.listRules()).where((r) => r.enabled).toList();
    if (rules.isEmpty) {
      log.info('tracking', 'no rules — skip scan');
      return const ScanResult(seen: 0, tracked: 0, ingested: 0);
    }

    await _ensurePermission();
    final roots = await _resolveRoots(rules);
    final now = DateTime.now().toUtc().toIso8601String();
    final regexRules = rules
        .where((r) => r.kind == TrackingRuleKind.regex)
        .map((r) => (rule: r, pattern: TrackingPattern.compile(r.patternOrUri)))
        .toList();
    final folderRules =
        rules.where((r) => r.kind == TrackingRuleKind.folder).toList();

    var seen = 0;
    var tracked = 0;
    final pendingIngest = <LocalTrackedFile>[];

    for (final root in roots) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        // Skip hidden / Android noise.
        final path = entity.path;
        if (path.contains('/.')) continue;
        seen += 1;

        final matched = _matchRule(
          path: path,
          regexRules: regexRules,
          folderRules: folderRules,
        );
        final stat = await entity.stat();
        final title = p.basename(path);
        final kind = sourceKindFromPath(path);

        if (matched != null) {
          tracked += 1;
          final existing = await repository.getLocalFile(path);
          final alreadySynced = existing?.isSynced ?? false;
          final row = LocalTrackedFile(
            localPath: path,
            ruleId: matched.id,
            fileId: alreadySynced ? existing!.fileId : null,
            contentHash: alreadySynced ? existing!.contentHash : null,
            title: title,
            sizeBytes: stat.size,
            mimeType: null,
            sourceKind: kind,
            seenAt: now,
            ingestStatus:
                alreadySynced ? IngestStatus.synced : IngestStatus.pending,
          );
          await repository.upsertLocalFile(row);
          if (!alreadySynced) pendingIngest.add(row);
        } else {
          await repository.upsertLocalFile(
            LocalTrackedFile(
              localPath: path,
              ruleId: null,
              title: title,
              sizeBytes: stat.size,
              sourceKind: kind,
              seenAt: now,
              ingestStatus: IngestStatus.untracked,
            ),
          );
        }
      }
    }

    var ingested = 0;
    if (ingestMatches) {
      for (final row in pendingIngest) {
        try {
          final bytes = await File(row.localPath).readAsBytes();
          final ruleName = rules
              .firstWhere(
                (r) => r.id == row.ruleId,
                orElse: () => TrackingRule(
                  id: row.ruleId!,
                  name: 'misc',
                  kind: TrackingRuleKind.regex,
                  patternOrUri: '',
                  enabled: true,
                  createdAt: now,
                ),
              )
              .name;
          final file = await ingest.ingestBytes(
            bytes,
            title: row.title,
            sourceKind: row.sourceKind,
            relativePath: 'track/$ruleName/${row.title ?? p.basename(row.localPath)}',
          );
          await repository.markSynced(
            localPath: row.localPath,
            fileId: file.fileId,
            contentHash: file.contentHash,
          );
          ingested += 1;
        } catch (e) {
          log.warn('tracking', 'ingest failed ${row.localPath}: $e');
          await repository.markFailed(row.localPath);
        }
      }
    }

    log.info(
      'tracking',
      'scan seen=$seen tracked=$tracked ingested=$ingested',
    );
    return ScanResult(seen: seen, tracked: tracked, ingested: ingested);
  }

  TrackingRule? _matchRule({
    required String path,
    required List<({TrackingRule rule, TrackingPattern pattern})> regexRules,
    required List<TrackingRule> folderRules,
  }) {
    final norm = p.normalize(path);
    for (final folder in folderRules) {
      final root = p.normalize(folder.patternOrUri);
      if (norm == root || norm.startsWith('$root${Platform.pathSeparator}') ||
          norm.startsWith('$root/')) {
        return folder;
      }
    }
    for (final entry in regexRules) {
      if (entry.pattern.matchesPath(norm)) return entry.rule;
    }
    return null;
  }

  Future<void> _ensurePermission() async {
    if (_scanRootsOverride != null) return;
    // Prefer all-files access when available; fall back to storage read.
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    if (!status.isGranted) {
      final storage = await Permission.storage.request();
      if (!storage.isGranted) {
        log.warn('tracking', 'storage permission not granted');
      }
    }
  }

  Future<List<Directory>> _resolveRoots(List<TrackingRule> rules) async {
    final override = _scanRootsOverride;
    if (override != null) return override;

    final dirs = <Directory>[];
    // Primary shared storage (full walk for regex rules).
    const candidates = [
      '/storage/emulated/0',
      '/sdcard',
    ];
    for (final c in candidates) {
      final d = Directory(c);
      if (await d.exists()) {
        dirs.add(d);
        break;
      }
    }
    // Always include explicit folder-rule roots.
    for (final r in rules.where((r) => r.kind == TrackingRuleKind.folder)) {
      final d = Directory(r.patternOrUri);
      if (await d.exists() && !dirs.any((x) => x.path == d.path)) {
        dirs.add(d);
      }
    }
    return dirs;
  }
}

class ScanResult {
  const ScanResult({
    required this.seen,
    required this.tracked,
    required this.ingested,
  });

  final int seen;
  final int tracked;
  final int ingested;
}
