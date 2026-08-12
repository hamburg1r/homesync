import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_repository.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;

/// Auto-pin catalog files under subscribed path prefixes onto the phone.
@lazySingleton
class FolderPinService {
  FolderPinService({
    required this.subscriptions,
    required this.repository,
    required this.pinService,
    required this.log,
  });

  final FolderPinRepository subscriptions;
  final CatalogRepository repository;
  final PinService pinService;
  final AppLog log;

  bool _busy = false;

  /// Reconcile every enabled subscription. Returns how many files pinned.
  Future<int> reconcileAll({
    void Function(IngestFileProgress progress)? onProgress,
  }) async {
    if (_busy) {
      log.info('folder_pin', 'reconcile ignored — already running');
      return 0;
    }
    _busy = true;
    try {
      final subs = await subscriptions.list(enabledOnly: true);
      if (subs.isEmpty) return 0;
      var pinned = 0;
      for (final sub in subs) {
        pinned += await _reconcileOne(sub, onProgress: onProgress);
      }
      return pinned;
    } finally {
      _busy = false;
    }
  }

  Future<int> reconcile(
    FolderPinSubscription sub, {
    void Function(IngestFileProgress progress)? onProgress,
  }) async {
    if (_busy) {
      log.info('folder_pin', 'reconcile ignored — already running');
      return 0;
    }
    _busy = true;
    try {
      return await _reconcileOne(sub, onProgress: onProgress);
    } finally {
      _busy = false;
    }
  }

  Future<int> _reconcileOne(
    FolderPinSubscription sub, {
    void Function(IngestFileProgress progress)? onProgress,
  }) async {
    final withPaths = await repository.listActiveFilesWithPrimaryPaths();
    final matches = <({CatalogFile file, String relativePath})>[
      for (final row in withPaths)
        if (pathMatchesFolderPinPrefix(row.relativePath, sub.pathPrefix)) row,
    ];
    final wantIds = {for (final m in matches) m.file.fileId};

    void emitProgress({
      required String title,
      required int index,
      required int total,
    }) {
      onProgress?.call(
        IngestFileProgress(
          phase: 'downloading',
          title: '${sub.name}: $title',
          index: index,
          total: total,
          fraction: total <= 0 ? 1.0 : index / total,
        ),
      );
    }

    emitProgress(title: 'Keeping folder on device…', index: 0, total: matches.length);

    var pinned = 0;
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      emitProgress(
        title: m.file.displayName,
        index: i + 1,
        total: matches.length,
      );
      try {
        final did = await _ensurePinnedUnderSubscription(sub, m);
        if (did) pinned += 1;
      } catch (e) {
        log.warn(
          'folder_pin',
          'pin failed ${m.file.fileId} under ${sub.pathPrefix}: $e',
        );
      }
    }

    await _cleanupOrphans(sub, wantIds);
    return pinned;
  }

  Future<bool> _ensurePinnedUnderSubscription(
    FolderPinSubscription sub,
    ({CatalogFile file, String relativePath}) match,
  ) async {
    final rel = pathRelativeToFolderPinPrefix(
      match.relativePath,
      sub.pathPrefix,
    );
    final abs = p.join(sub.localRoot, rel);
    final dir = p.dirname(abs);
    final name = p.basename(abs);
    final destFile = File(abs);

    final existingPin =
        await repository.pinLocalPathForFileId(match.file.fileId);
    if (existingPin != null &&
        existingPin == abs &&
        await destFile.exists() &&
        await destFile.length() == match.file.sizeBytes) {
      if (!match.file.isPinned) {
        await pinService.pin(
          match.file.fileId,
          destination: PinDestination(
            directory: dir,
            fileName: name,
            overwrite: true,
          ),
        );
      }
      if (!match.file.boundToServer) {
        await repository.setBoundToServer(match.file.fileId, bound: true);
      }
      return false;
    }

    if (existingPin != null && existingPin != abs) {
      await repository.clearPinLocalPath(
        match.file.fileId,
        deleteFile: true,
      );
    } else if (existingPin == abs && await destFile.exists()) {
      await destFile.delete();
      await repository.clearPinLocalPath(
        match.file.fileId,
        deleteFile: false,
      );
    }

    await pinService.pin(
      match.file.fileId,
      destination: PinDestination(
        directory: dir,
        fileName: name,
        overwrite: true,
      ),
    );
    await repository.setBoundToServer(match.file.fileId, bound: true);
    log.info('folder_pin', 'pinned ${match.file.fileId} → $abs');
    return true;
  }

  Future<void> _cleanupOrphans(
    FolderPinSubscription sub,
    Set<String> wantIds,
  ) async {
    final root = p.normalize(sub.localRoot);
    final pinRows = await repository.listPinLocalPaths();
    for (final row in pinRows) {
      if (wantIds.contains(row.fileId)) continue;
      final path = p.normalize(row.absolutePath);
      final sep = Platform.pathSeparator;
      if (path != root && !path.startsWith('$root$sep')) {
        continue;
      }
      try {
        await pinService.keepOnPcOnly(row.fileId);
        log.info('folder_pin', 'removed orphan pin ${row.fileId}');
      } catch (e) {
        log.warn('folder_pin', 'orphan cleanup ${row.fileId}: $e');
        await repository.clearPinLocalPath(row.fileId);
        await repository.clearBoundToServer(row.fileId);
      }
    }
  }
}
