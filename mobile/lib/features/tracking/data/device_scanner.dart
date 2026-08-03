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
  /// [forceFullScan] clears leftover dir-mtime cache under the walk roots.
  /// [limitRoots] walks only these directories when set (drawer group pull).
  Future<ScanResult> scanAndIngest({
    bool ingestMatches = true,
    bool forceFullScan = false,
    List<Directory>? limitRoots,
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
    final roots = limitRoots ?? await _resolveRoots(rules);
    final now = DateTime.now().toUtc().toIso8601String();
    final topLevelRegex = rules
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

    // One-shot local index (avoid per-file SELECTs). Always list + recurse +
    // re-stat: dir mtime does not cover nested dirs or in-place file edits.
    final byPath = await repository.mapLocalFilesByPath();
    if (forceFullScan) {
      if (limitRoots != null) {
        for (final root in limitRoots) {
          await repository.clearScanDirCache(
            underPrefix: p.normalize(root.path),
          );
        }
      } else {
        await repository.clearScanDirCache();
      }
    }

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
      required TrackingRuleMatch? matched,
      LocalTrackedFile? existing,
    }) async {
      final norm = p.normalize(path);
      if (!seenPaths.add(norm)) return;
      seen += 1;
      final title = p.basename(path);
      final kind = matched?.sourceKindOverride ?? sourceKindFromPath(path);
      final prior = existing ?? byPath[norm];

      if (matched != null) {
        tracked += 1;
        final sizeUnchanged =
            prior != null && prior.sizeBytes == sizeBytes;
        final mtimeUnchanged =
            prior?.mtimeMs != null && prior!.mtimeMs == mtimeMs;
        final mtimeOkForSkip = mtimeUnchanged ||
            (prior != null &&
                prior.isSynced &&
                prior.mtimeMs == null &&
                sizeUnchanged);
        final metadataUnchanged = sizeUnchanged && mtimeOkForSkip;
        final hasDigest =
            prior?.contentHash != null && prior!.contentHash!.isNotEmpty;

        late final LocalTrackedFile next;
        if (prior != null &&
            prior.isSynced &&
            metadataUnchanged &&
            hasDigest) {
          next = LocalTrackedFile(
            localPath: path,
            ruleId: matched.rule.id,
            fileId: prior.fileId,
            contentHash: prior.contentHash,
            title: title,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
            mimeType: prior.mimeType,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: IngestStatus.synced,
          );
        } else if (prior != null && metadataUnchanged && hasDigest) {
          final status = prior.ingestStatus == IngestStatus.failed
              ? IngestStatus.failed
              : IngestStatus.pending;
          next = LocalTrackedFile(
            localPath: path,
            ruleId: matched.rule.id,
            fileId: prior.fileId,
            contentHash: prior.contentHash,
            title: title,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
            mimeType: prior.mimeType,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: status,
          );
        } else {
          next = LocalTrackedFile(
            localPath: path,
            ruleId: matched.rule.id,
            fileId: prior?.fileId,
            contentHash: metadataUnchanged ? prior.contentHash : null,
            title: title,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
            mimeType: prior?.mimeType,
            sourceKind: kind,
            seenAt: now,
            ingestStatus: IngestStatus.pending,
          );
        }
        await repository.upsertLocalFile(next);
        byPath[norm] = next;
      } else {
        final next = LocalTrackedFile(
          localPath: path,
          ruleId: null,
          title: title,
          sizeBytes: sizeBytes,
          mtimeMs: mtimeMs,
          sourceKind: kind,
          seenAt: now,
          ingestStatus: IngestStatus.untracked,
        );
        await repository.upsertLocalFile(next);
        byPath[norm] = next;
      }
      reportScan();
    }

    Future<void> walkDir(Directory dir) async {
      final dirNorm = p.normalize(dir.path);
      if (_shouldSkipDir(dirNorm)) return;

      final Stream<FileSystemEntity> listing;
      try {
        listing = dir.list(followLinks: false);
      } on FileSystemException catch (e) {
        log.warn('tracking', 'skip inaccessible $dirNorm: $e');
        return;
      }

      final subdirs = <Directory>[];
      await for (final entity in listing.handleError(
        (Object e, StackTrace _) {
          log.warn('tracking', 'skip inaccessible under $dirNorm: $e');
        },
        test: (e) => e is FileSystemException,
      )) {
        if (entity is File) {
          final path = entity.path;
          if (path.contains('/.')) continue;
          final matched = _matchRule(
            path: path,
            topLevelRegex: topLevelRegex,
            folderRules: folderRules,
            fileRulePaths: fileRulePaths,
          );
          try {
            final stat = await entity.stat();
            await consider(
              path: path,
              sizeBytes: stat.size,
              mtimeMs: stat.modified.millisecondsSinceEpoch,
              matched: matched,
              existing: byPath[p.normalize(path)],
            );
          } on FileSystemException catch (e) {
            log.warn('tracking', 'skip file $path: $e');
          }
        } else if (entity is Directory) {
          if (_shouldSkipDir(entity.path)) continue;
          subdirs.add(entity);
        }
      }

      // Always recurse — parent mtime does not reflect nested changes.
      for (final sub in subdirs) {
        await walkDir(sub);
      }
    }

    for (final root in roots) {
      if (!await root.exists()) continue;
      await walkDir(root);
    }

    // File rules: ensure exact paths are considered even if not under a walk root.
    for (final rule in fileRules) {
      final file = File(rule.patternOrUri);
      if (!await file.exists()) continue;
      final path = file.path;
      if (path.contains('/.')) continue;
      if (limitRoots != null &&
          !limitRoots.any((r) => _isUnderRoot(path, r.path))) {
        continue;
      }
      try {
        final stat = await file.stat();
        await consider(
          path: path,
          sizeBytes: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
          matched: TrackingRuleMatch(rule: rule, contributing: [rule]),
          existing: byPath[p.normalize(path)],
        );
      } on FileSystemException catch (e) {
        log.warn('tracking', 'skip file rule $path: $e');
      }
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
      'scan seen=$seen tracked=$tracked ingested=$ingested '
      'forceFull=$forceFullScan',
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
    final byId = indexTrackingRules(rules);
    final ctx = _MatchContext.fromForest(rules);
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
        final match = _matchRule(
          path: row.localPath,
          topLevelRegex: ctx.topLevelRegex,
          folderRules: ctx.folderRules,
          fileRulePaths: ctx.fileRulePaths,
        );
        final meta = resolveTrackingIngestMeta(byId, row, match: match);
        final source = File(row.localPath);
        final reuseHash = await _canReuseContentHash(row, source);
        final item = await ingest.enqueueFile(
          source,
          title: row.title,
          sourceKind: match?.sourceKindOverride ?? row.sourceKind,
          relativePath: meta.relativePath,
          replaceFileId: row.fileId,
          knownContentHash: reuseHash ? row.contentHash : null,
          tags: meta.tags,
          index: i + 1,
          total: total,
          onProgress: onProgress,
        );
        // Persist digest immediately so a killed upload does not re-blake3.
        if (row.contentHash != item.contentHash) {
          await repository.upsertLocalFile(
            LocalTrackedFile(
              localPath: row.localPath,
              ruleId: row.ruleId,
              fileId: row.fileId,
              contentHash: item.contentHash,
              title: row.title,
              sizeBytes: item.sizeBytes,
              mtimeMs: (await source.stat()).modified.millisecondsSinceEpoch,
              mimeType: row.mimeType,
              sourceKind: row.sourceKind,
              seenAt: row.seenAt,
              ingestStatus: IngestStatus.pending,
            ),
          );
        }
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
    final byId = indexTrackingRules(rules);
    final ctx = _MatchContext.fromForest(rules);
    final pending = await repository.listNeedingIngest();
    if (pending.isEmpty) return 0;

    var ingested = 0;
    final total = pending.length;
    for (var i = 0; i < total; i++) {
      final row = pending[i];
      try {
        final match = _matchRule(
          path: row.localPath,
          topLevelRegex: ctx.topLevelRegex,
          folderRules: ctx.folderRules,
          fileRulePaths: ctx.fileRulePaths,
        );
        final meta = resolveTrackingIngestMeta(byId, row, match: match);
        final source = File(row.localPath);
        final reuseHash = await _canReuseContentHash(row, source);
        final file = await ingest.ingestFile(
          source,
          title: row.title,
          sourceKind: match?.sourceKindOverride ?? row.sourceKind,
          relativePath: meta.relativePath,
          replaceFileId: row.fileId,
          previousContentHash: row.contentHash,
          knownContentHash: reuseHash ? row.contentHash : null,
          tags: meta.tags,
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

  /// True when the local index digest still matches this on-disk revision.
  Future<bool> _canReuseContentHash(LocalTrackedFile row, File source) async {
    final digest = row.contentHash;
    if (digest == null || digest.isEmpty) return false;
    if (row.mtimeMs == null) return false;
    final stat = await source.stat();
    return stat.size == row.sizeBytes &&
        stat.modified.millisecondsSinceEpoch == row.mtimeMs;
  }

  TrackingRuleMatch? _matchRule({
    required String path,
    required List<({TrackingRule rule, TrackingPattern pattern})> topLevelRegex,
    required List<TrackingRule> folderRules,
    required Map<String, TrackingRule> fileRulePaths,
  }) {
    final norm = p.normalize(path);
    final contributing = <TrackingRule>[];
    TrackingRule? primary;
    TrackingRule? folderParent;
    String? folderRoot;

    final fileHit = fileRulePaths[norm];
    if (fileHit != null) {
      contributing.add(fileHit);
      primary = fileHit;
    }

    for (final folder in folderRules) {
      final root = p.normalize(folder.patternOrUri);
      if (!_isUnderRoot(norm, root)) continue;
      final enabledChildren =
          folder.children.where((c) => c.enabled).toList(growable: false);
      // Children present ⇒ include-only (never fall back to whole tree).
      // No children ⇒ track every file under the folder.
      if (folder.children.isNotEmpty) {
        if (enabledChildren.isEmpty) continue;
        final rel = _relativeUnderRoot(norm, root);
        TrackingRule? childHit;
        for (final child in enabledChildren) {
          final pattern = TrackingPattern.compile(child.patternOrUri);
          if (pattern.matchesPath(rel) || pattern.matchesPath(norm)) {
            childHit = child;
            break;
          }
        }
        if (childHit == null) continue;
        contributing.add(folder);
        contributing.add(childHit);
        if (primary == null) {
          primary = childHit;
          folderParent = folder;
          folderRoot = root;
        }
        continue;
      }
      contributing.add(folder);
      if (primary == null) {
        primary = folder;
        folderRoot = root;
      }
    }

    for (final entry in topLevelRegex) {
      if (entry.pattern.matchesPath(norm)) {
        contributing.add(entry.rule);
        primary ??= entry.rule;
      }
    }

    if (primary == null) return null;
    return TrackingRuleMatch(
      rule: primary,
      folderParent: folderParent,
      folderRoot: folderRoot,
      contributing: List.unmodifiable(contributing),
    );
  }

  String _relativeUnderRoot(String path, String root) {
    final norm = p.normalize(path);
    final base = p.normalize(root);
    if (norm == base) return p.basename(norm);
    return p.relative(norm, from: base).replaceAll('\\', '/');
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

  /// After editing a rule's tags/source_kind, push updates for synced matches.
  ///
  /// Tags become `union(existing − oldRuleTags, all matching rules' tags)`.
  /// Source kind uses most-specific override among matches (else path heuristic).
  Future<RulePropagateResult> propagateRuleEdit({
    required TrackingRule before,
    required TrackingRule after,
  }) async {
    final forest =
        (await repository.listRules()).where((r) => r.enabled).toList();
    final ctx = _MatchContext.fromForest(forest);
    final tracked = await repository.listTracked();
    final removedTags = before.tags.toSet().difference(after.tags.toSet());
    var tagsUpdated = 0;
    var sourceKindUpdated = 0;

    for (final row in tracked) {
      final match = _matchRule(
        path: row.localPath,
        topLevelRegex: ctx.topLevelRegex,
        folderRules: ctx.folderRules,
        fileRulePaths: ctx.fileRulePaths,
      );
      if (match == null) continue;
      final touchesEdited = match.contributing.any((r) => r.id == after.id) ||
          match.rule.id == after.id ||
          (after.parentId != null && match.folderParent?.id == after.parentId);
      // Also refresh files still bound to this rule id (or its parent folder).
      final bound =
          row.ruleId == after.id || row.ruleId == before.id || touchesEdited;
      if (!bound && !touchesEdited) continue;

      final kind =
          match.sourceKindOverride ?? sourceKindFromPath(row.localPath);
      final tags = match.effectiveTags;
      final existing = row.fileId == null
          ? null
          : await ingest.repository.getFile(row.fileId!);
      final existingTags = existing?.tags ?? const <String>[];
      final nextTags = <String>{
        ...existingTags.where((t) => !removedTags.contains(t)),
        ...tags,
      }.toList()
        ..sort();

      if (row.sourceKind != kind) {
        await repository.upsertLocalFile(
          LocalTrackedFile(
            localPath: row.localPath,
            ruleId: match.rule.id,
            fileId: row.fileId,
            contentHash: row.contentHash,
            title: row.title,
            sizeBytes: row.sizeBytes,
            mtimeMs: row.mtimeMs,
            mimeType: row.mimeType,
            sourceKind: kind,
            seenAt: row.seenAt,
            ingestStatus: row.ingestStatus,
          ),
        );
      }

      final fileId = row.fileId;
      if (fileId == null || !row.isSynced) continue;

      if (!_listEqualsSorted(existingTags, nextTags)) {
        try {
          final updated =
              await ingest.api.putFileTags(fileId: fileId, tags: nextTags);
          await ingest.repository.upsertFile(updated);
          tagsUpdated += 1;
        } catch (e) {
          log.warn('tracking', 'tag propagate failed $fileId: $e');
        }
      }

      if (before.sourceKind != after.sourceKind || row.sourceKind != kind) {
        try {
          final base = existing?.updatedAt;
          final updated = await ingest.api.patchFile(
            fileId,
            sourceKind: kind,
            baseUpdatedAt: base,
          );
          await ingest.repository.upsertFile(updated);
          await ingest.repository.setLocalSourceKind(fileId, kind);
          sourceKindUpdated += 1;
        } catch (e) {
          log.warn('tracking', 'source_kind propagate failed $fileId: $e');
        }
      }
    }

    return RulePropagateResult(
      tagsUpdated: tagsUpdated,
      sourceKindUpdated: sourceKindUpdated,
    );
  }

  /// Disable/enable a rule; when disabling, cancel pending uploads for it.
  ///
  /// Returns how many pending/failed local rows were demoted. An upload already
  /// in flight may still finish; queued and not-yet-started work is dropped.
  Future<int> setRuleEnabled(TrackingRule rule, bool enabled) async {
    await repository.setRuleEnabled(rule.id, enabled);
    await repository.clearScanDirCache();
    if (enabled) return 0;
    final ids = await repository.ruleIdsAffectedBy(rule);
    final paths = await repository.cancelPendingForRuleIds(ids);
    if (paths.isNotEmpty) {
      await ingest.queue.removeBySourcePaths(paths);
    }
    log.info(
      'tracking',
      'disabled ${rule.name}: cancelled ${paths.length} pending',
    );
    return paths.length;
  }

  /// Drop directory mtime cache so the next scan re-walks every folder.
  Future<void> invalidateDirCache() => repository.clearScanDirCache();
}

class _MatchContext {
  _MatchContext({
    required this.topLevelRegex,
    required this.folderRules,
    required this.fileRulePaths,
  });

  final List<({TrackingRule rule, TrackingPattern pattern})> topLevelRegex;
  final List<TrackingRule> folderRules;
  final Map<String, TrackingRule> fileRulePaths;

  factory _MatchContext.fromForest(List<TrackingRule> rules) {
    return _MatchContext(
      topLevelRegex: rules
          .where((r) => r.kind == TrackingRuleKind.regex)
          .map((r) => (rule: r, pattern: TrackingPattern.compile(r.patternOrUri)))
          .toList(),
      folderRules: rules.where((r) => r.kind == TrackingRuleKind.folder).toList(),
      fileRulePaths: {
        for (final r in rules.where((r) => r.kind == TrackingRuleKind.file))
          p.normalize(r.patternOrUri): r,
      },
    );
  }
}

bool _listEqualsSorted(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final aa = [...a]..sort();
  final bb = [...b]..sort();
  for (var i = 0; i < aa.length; i++) {
    if (aa[i] != bb[i]) return false;
  }
  return true;
}

class RulePropagateResult {
  const RulePropagateResult({
    required this.tagsUpdated,
    required this.sourceKindUpdated,
  });

  final int tagsUpdated;
  final int sourceKindUpdated;
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
