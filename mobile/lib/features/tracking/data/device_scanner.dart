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
    @ignoreParam List<Directory>? scanRoots,
  }) : _scanRootsOverride = scanRoots;

  final TrackingRepository repository;
  final IngestService ingest;
  final AppLog log;
  final List<Directory>? _scanRootsOverride;

  /// Discover files, update local index, ingest pending tracked files.
  ///
  /// [onIndexed] runs after the local index is updated and before uploads,
  /// so the UI can show `pending` rows while ingest is in flight.
  Future<ScanResult> scanAndIngest({
    bool ingestMatches = true,
    IngestProgressCallback? onProgress,
    Future<void> Function()? onIndexed,
  }) async {
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
    final fileRules =
        rules.where((r) => r.kind == TrackingRuleKind.file).toList();
    final fileRulePaths = {
      for (final r in fileRules) p.normalize(r.patternOrUri): r,
    };

    var seen = 0;
    var tracked = 0;
    final seenPaths = <String>{};

    Future<void> consider({
      required String path,
      required int sizeBytes,
      required TrackingRule? matched,
    }) async {
      final norm = p.normalize(path);
      if (!seenPaths.add(norm)) return;
      seen += 1;
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
          sizeBytes: sizeBytes,
          mimeType: null,
          sourceKind: kind,
          seenAt: now,
          ingestStatus:
              alreadySynced ? IngestStatus.synced : IngestStatus.pending,
        );
        await repository.upsertLocalFile(row);
      } else {
        await repository.upsertLocalFile(
          LocalTrackedFile(
            localPath: path,
            ruleId: null,
            title: title,
            sizeBytes: sizeBytes,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: IngestStatus.untracked,
          ),
        );
      }
    }

    for (final root in roots) {
      if (!await root.exists()) continue;
      await for (final entity in _listFilesSafe(root)) {
        final path = entity.path;
        if (path.contains('/.')) continue;
        final matched = _matchRule(
          path: path,
          regexRules: regexRules,
          folderRules: folderRules,
          fileRulePaths: fileRulePaths,
        );
        final stat = await entity.stat();
        await consider(
          path: path,
          sizeBytes: stat.size,
          matched: matched,
        );
      }
    }

    // File rules: ensure exact paths are considered even if not under a walk root.
    for (final rule in fileRules) {
      final file = File(rule.patternOrUri);
      if (!await file.exists()) continue;
      final path = file.path;
      if (path.contains('/.')) continue;
      final size = (await file.stat()).size;
      await consider(path: path, sizeBytes: size, matched: rule);
    }

    var ingested = 0;
    if (onIndexed != null) {
      await onIndexed();
    }
    if (ingestMatches) {
      ingested = await ingestPending(onProgress: onProgress);
    }

    log.info(
      'tracking',
      'scan seen=$seen tracked=$tracked ingested=$ingested',
    );
    return ScanResult(seen: seen, tracked: tracked, ingested: ingested);
  }

  /// Upload pending/failed tracked files (and leave durable queue flush to caller).
  Future<int> ingestPending({IngestProgressCallback? onProgress}) async {
    final rules =
        (await repository.listRules()).where((r) => r.enabled).toList();
    final ruleNames = {for (final r in rules) r.id: r.name};
    final pending = await repository.listNeedingIngest();
    if (pending.isEmpty) return 0;

    var ingested = 0;
    final total = pending.length;
    for (var i = 0; i < total; i++) {
      final row = pending[i];
      try {
        final ruleName = ruleNames[row.ruleId] ?? 'misc';
        final file = await ingest.ingestFile(
          File(row.localPath),
          title: row.title,
          sourceKind: row.sourceKind,
          relativePath:
              'track/$ruleName/${row.title ?? p.basename(row.localPath)}',
          index: i + 1,
          total: total,
          onProgress: onProgress,
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
    return ingested;
  }

  TrackingRule? _matchRule({
    required String path,
    required List<({TrackingRule rule, TrackingPattern pattern})> regexRules,
    required List<TrackingRule> folderRules,
    required Map<String, TrackingRule> fileRulePaths,
  }) {
    final norm = p.normalize(path);
    final fileHit = fileRulePaths[norm];
    if (fileHit != null) return fileHit;
    for (final folder in folderRules) {
      if (_isUnderRoot(norm, folder.patternOrUri)) return folder;
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
    // Full shared-storage walk only when regex rules need it.
    final hasRegex = rules.any((r) => r.kind == TrackingRuleKind.regex);
    if (hasRegex) {
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
    }
    // Explicit folder-rule roots (skip if already covered by a parent root).
    for (final r in rules.where((r) => r.kind == TrackingRuleKind.folder)) {
      final d = Directory(r.patternOrUri);
      if (!await d.exists()) continue;
      final covered = dirs.any((x) => _isUnderRoot(d.path, x.path));
      if (!covered) dirs.add(d);
    }
    return dirs;
  }

  /// Breadth-first walk that skips inaccessible / privacy-sandbox dirs.
  Stream<File> _listFilesSafe(Directory root) async* {
    final queue = <Directory>[root];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      final Stream<FileSystemEntity> listing;
      try {
        listing = dir.list(followLinks: false);
      } on FileSystemException catch (e) {
        log.warn('tracking', 'skip inaccessible ${dir.path}: $e');
        continue;
      }
      await for (final entity in listing.handleError(
        (Object e, StackTrace _) {
          log.warn('tracking', 'skip inaccessible under ${dir.path}: $e');
        },
        test: (e) => e is FileSystemException,
      )) {
        if (entity is File) {
          yield entity;
        } else if (entity is Directory) {
          if (_shouldSkipDir(entity.path)) continue;
          queue.add(entity);
        }
      }
    }
  }

  bool _shouldSkipDir(String path) {
    final norm = p.normalize(path);
    // App-private sandboxes are unreadable without special access and abort
    // naive recursive listing on Android 11+.
    if (norm.contains('${Platform.pathSeparator}Android${Platform.pathSeparator}data') ||
        norm.contains('${Platform.pathSeparator}Android${Platform.pathSeparator}obb') ||
        norm.endsWith('${Platform.pathSeparator}Android${Platform.pathSeparator}data') ||
        norm.endsWith('${Platform.pathSeparator}Android${Platform.pathSeparator}obb')) {
      return true;
    }
    return false;
  }

  bool _isUnderRoot(String path, String root) {
    final norm = p.normalize(path);
    final base = p.normalize(root);
    return norm == base ||
        norm.startsWith('$base${Platform.pathSeparator}') ||
        norm.startsWith('$base/');
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
