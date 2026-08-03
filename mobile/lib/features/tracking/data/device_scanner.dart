import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
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
  /// [onProgress] receives `scanning` updates while walking storage.
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

    onProgress?.call(
      const IngestFileProgress(
        title: 'device storage',
        index: 0,
        total: 0,
        phase: 'scanning',
        fraction: 0,
      ),
    );

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
    var lastScanReport = DateTime.fromMillisecondsSinceEpoch(0);

    void reportScan() {
      final nowLocal = DateTime.now();
      if (seen > 0 &&
          nowLocal.difference(lastScanReport) < const Duration(milliseconds: 250)) {
        return;
      }
      lastScanReport = nowLocal;
      onProgress?.call(
        IngestFileProgress(
          title: tracked > 0
              ? '$seen files ($tracked tracked)'
              : '$seen files',
          index: seen,
          total: 0,
          phase: 'scanning',
          fraction: 0,
        ),
      );
    }

    Future<void> consider({
      required String path,
      required int sizeBytes,
      required int mtimeMs,
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
        if (alreadySynced) {
          final sizeUnchanged = existing!.sizeBytes == sizeBytes;
          final mtimeUnchanged =
              existing.mtimeMs != null && existing.mtimeMs == mtimeMs;
          if (sizeUnchanged && mtimeUnchanged) {
            await repository.upsertLocalFile(
              LocalTrackedFile(
                localPath: path,
                ruleId: matched.id,
                fileId: existing.fileId,
                contentHash: existing.contentHash,
                title: title,
                sizeBytes: sizeBytes,
                mtimeMs: mtimeMs,
                mimeType: existing.mimeType,
                sourceKind: kind,
                seenAt: now,
                ingestStatus: IngestStatus.synced,
              ),
            );
          } else {
            // Bytes may have changed — rehash on ingest; keep fileId binding.
            await repository.upsertLocalFile(
              LocalTrackedFile(
                localPath: path,
                ruleId: matched.id,
                fileId: existing.fileId,
                contentHash: existing.contentHash,
                title: title,
                sizeBytes: sizeBytes,
                mtimeMs: mtimeMs,
                mimeType: existing.mimeType,
                sourceKind: kind,
                seenAt: now,
                ingestStatus: IngestStatus.pending,
              ),
            );
          }
        } else {
          final row = LocalTrackedFile(
            localPath: path,
            ruleId: matched.id,
            fileId: existing?.fileId,
            contentHash: existing?.contentHash,
            title: title,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
            mimeType: existing?.mimeType,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: IngestStatus.pending,
          );
          await repository.upsertLocalFile(row);
        }
      } else {
        await repository.upsertLocalFile(
          LocalTrackedFile(
            localPath: path,
            ruleId: null,
            title: title,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: IngestStatus.untracked,
          ),
        );
      }
      reportScan();
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
          mtimeMs: stat.modified.millisecondsSinceEpoch,
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
      final mtimeMs = (await file.stat()).modified.millisecondsSinceEpoch;
      await consider(
        path: path,
        sizeBytes: size,
        mtimeMs: mtimeMs,
        matched: rule,
      );
    }

    onProgress?.call(
      IngestFileProgress(
        title: tracked > 0
            ? '$seen files ($tracked tracked)'
            : '$seen files',
        index: seen,
        total: 0,
        phase: 'scanning',
        fraction: 1,
      ),
    );

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

  /// Pending tracked files that are not already in the durable ingest queue.
  ///
  /// Used to hand path+metadata to the FG task isolate (hash runs there so
  /// backgrounding the UI does not pause prepare).
  Future<List<LocalTrackedFile>> listPendingNotQueued() async {
    final pending = await repository.listNeedingIngest();
    if (pending.isEmpty) return const [];
    final queuedPaths = {
      for (final item in await ingest.queue.list())
        if (item.sourcePath != null) item.sourcePath!,
    };
    return [
      for (final row in pending)
        if (!queuedPaths.contains(row.localPath)) row,
    ];
  }

  /// Hash pending/failed tracked files into the durable ingest queue (no upload).
  Future<int> enqueuePending({IngestProgressCallback? onProgress}) async {
    final rules =
        (await repository.listRules()).where((r) => r.enabled).toList();
    final ruleNames = {for (final r in rules) r.id: r.name};
    final pending = await repository.listNeedingIngest();
    if (pending.isEmpty) return 0;

    final alreadyQueued = {
      for (final item in await ingest.queue.list())
        if (item.sourcePath != null) item.sourcePath!,
    };

    var enqueued = 0;
    final total = pending.length;
    for (var i = 0; i < total; i++) {
      final row = pending[i];
      final display = row.title ?? p.basename(row.localPath);
      if (alreadyQueued.contains(row.localPath)) {
        enqueued += 1;
        onProgress?.call(
          IngestFileProgress(
            title: display,
            index: i + 1,
            total: total,
            phase: 'hashing',
            fraction: 1,
          ),
        );
        continue;
      }
      try {
        final ruleName = ruleNames[row.ruleId] ?? 'misc';
        final source = File(row.localPath);
        final item = await ingest.enqueueFile(
          source,
          title: row.title,
          sourceKind: row.sourceKind,
          relativePath:
              'track/$ruleName/${row.title ?? p.basename(row.localPath)}',
          replaceFileId: row.fileId,
          index: i + 1,
          total: total,
          onProgress: onProgress,
        );
        if (row.fileId != null &&
            row.contentHash != null &&
            item.contentHash == row.contentHash) {
          // Touch-only: size/mtime changed but bytes match last head.
          await repository.markSynced(
            localPath: row.localPath,
            fileId: row.fileId!,
            contentHash: item.contentHash,
            sizeBytes: item.sizeBytes,
            mtimeMs: (await source.stat()).modified.millisecondsSinceEpoch,
          );
          await ingest.queue.remove(item.id);
        } else {
          alreadyQueued.add(row.localPath);
          enqueued += 1;
        }
      } catch (e) {
        log.warn('tracking', 'enqueue failed ${row.localPath}: $e');
        await repository.markFailed(row.localPath);
      }
    }
    return enqueued;
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
        final source = File(row.localPath);
        final file = await ingest.ingestFile(
          source,
          title: row.title,
          sourceKind: row.sourceKind,
          relativePath:
              'track/$ruleName/${row.title ?? p.basename(row.localPath)}',
          replaceFileId: row.fileId,
          previousContentHash: row.contentHash,
          index: i + 1,
          total: total,
          onProgress: onProgress,
        );
        await repository.markSynced(
          localPath: row.localPath,
          fileId: file.fileId,
          contentHash: file.contentHash,
          sizeBytes: file.sizeBytes,
          mtimeMs: (await source.stat()).modified.millisecondsSinceEpoch,
        );
        ingested += 1;
      } on KdbxConflictPendingException catch (e) {
        log.warn(
          'tracking',
          'KeePass conflict for ${row.localPath}: ${e.conflict.conflictId}',
        );
        // Server head unchanged — keep prior binding; resolve via Conflicts outbox.
        if (row.fileId != null && row.contentHash != null) {
          await repository.markSynced(
            localPath: row.localPath,
            fileId: row.fileId!,
            contentHash: row.contentHash!,
            sizeBytes: row.sizeBytes,
            mtimeMs: row.mtimeMs,
          );
        }
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
