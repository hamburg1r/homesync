import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:homesync_mobile/features/catalog/data/sync/background_ingest_runner.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/deletion_outbox.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/thumb_service.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_filters.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_tree.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_state.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';
import 'package:injectable/injectable.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

export 'package:homesync_mobile/features/catalog/presentation/catalog_state.dart';

/// Catalog UI state: watches local Drift rows + drives delta refresh / pin.
@injectable
class CatalogCubit extends Cubit<CatalogState> {
  CatalogCubit({
    required this.repository,
    required this.sync,
    required this.api,
    required this.pinService,
    required this.thumbService,
    required this.tracking,
    required this.scanner,
    required this.backgroundIngest,
    required this.deletionOutbox,
    required this.settings,
    required this.log,
  }) : super(CatalogState(
          syncEnabled: settings.syncEnabled,
          foldersView: settings.foldersView,
        )) {
    _filesSub = repository.watchActiveFiles().listen(_onCatalogFiles);
    _rulesSub = tracking.watchRules().listen((rules) {
      if (!isClosed) emit(state.copyWith(rules: rules));
    });
    settings.addListener(_onSettingsChanged);
  }

  final CatalogRepository repository;
  final CatalogSync sync;
  final HomesyncApi api;
  final PinService pinService;
  final ThumbService thumbService;
  final TrackingRepository tracking;
  final DeviceScanner scanner;
  final BackgroundIngestRunner backgroundIngest;
  final DeletionOutbox deletionOutbox;
  final SettingsStore settings;
  final AppLog log;
  StreamSubscription<List<CatalogFile>>? _filesSub;
  StreamSubscription<List<TrackingRule>>? _rulesSub;
  List<CatalogFile> _catalogFiles = const [];
  bool _started = false;
  bool _refreshBusy = false;
  DateTime? _lastIngestProgressEmit;
  IngestFileProgress? _lastIngestProgress;

  void _onSettingsChanged() {
    if (isClosed) return;
    var next = state;
    if (state.syncEnabled != settings.syncEnabled) {
      next = next.copyWith(syncEnabled: settings.syncEnabled);
    }
    if (state.foldersView != settings.foldersView) {
      next = next.copyWith(
        foldersView: settings.foldersView,
        clearTreePrefix: !settings.foldersView,
      );
    }
    if (!identical(next, state) && next != state) {
      emit(next);
      if (state.foldersView != settings.foldersView) {
        unawaited(_emitBrowseList());
      }
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    log.info('catalog', 'cubit start');
    final rules = await tracking.listRules();
    final pendingDeletes = await deletionOutbox.pendingFileIds();
    if (!isClosed) {
      emit(
        state.copyWith(
          rules: rules,
          syncEnabled: settings.syncEnabled,
          pendingDeletionIds: pendingDeletes,
        ),
      );
    }
    await refresh(showSpinnerWhenEmpty: true);
  }

  String? get currentDeviceId => sync.identity.currentDeviceId;

  Future<List<DeviceInfo>> listServerDevices() => api.listDevices();

  Future<String?> reclaimDeviceId(String deviceId) async {
    emit(state.copyWith(refreshing: true, clearStatusMessage: true));
    try {
      final result = await sync.reclaimDevice(deviceId);
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!result.ok) {
        final msg = result.error?.toString() ?? 'reclaim failed';
        if (!isClosed) {
          emit(state.copyWith(refreshing: false, statusMessage: msg));
        }
        return msg;
      }
      if (!isClosed) {
        emit(state.copyWith(refreshing: false));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'reclaim device failed: $e');
      if (!isClosed) {
        emit(state.copyWith(refreshing: false, statusMessage: e.toString()));
      }
      return e.toString();
    }
  }

  Future<String?> resetDeviceId() async {
    emit(state.copyWith(refreshing: true, clearStatusMessage: true));
    try {
      final result = await sync.resetDeviceIdentity();
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!result.ok) {
        final msg = result.error?.toString() ?? 'reset failed';
        if (!isClosed) {
          emit(state.copyWith(refreshing: false, statusMessage: msg));
        }
        return msg;
      }
      if (!isClosed) {
        emit(state.copyWith(refreshing: false));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'reset device failed: $e');
      if (!isClosed) {
        emit(state.copyWith(refreshing: false, statusMessage: e.toString()));
      }
      return e.toString();
    }
  }

  void _onCatalogFiles(List<CatalogFile> files) {
    _catalogFiles = files;
    if (isClosed) return;
    if (state.browseMode != BrowseMode.allCatalog) {
      unawaited(_emitBrowseList());
      return;
    }
    _emitFilteredCatalog(files);
  }

  void _emitFilteredCatalog(List<CatalogFile> files) {
    final filtered = applyCatalogSearch(
      applyDeviceSyncedFilter(files, enabled: state.deviceAndSyncedOnly),
      query: state.searchQuery,
    );
    if (state.refreshing) {
      emit(state.copyWith(files: filtered));
      return;
    }
    if (state.viewState == CatalogViewState.error ||
        state.viewState == CatalogViewState.degraded) {
      emit(state.copyWith(files: filtered));
      return;
    }
    emit(
      state.copyWith(
        files: filtered,
        viewState:
            filtered.isEmpty ? CatalogViewState.empty : CatalogViewState.ready,
        clearStatusMessage: true,
      ),
    );
  }

  Future<void> setSearchQuery(String query) async {
    emit(state.copyWith(searchQuery: query));
    await _emitBrowseList();
  }

  Future<void> setBrowseMode(
    BrowseMode mode, {
    String? groupRuleId,
    String? groupTitle,
  }) async {
    emit(
      state.copyWith(
        browseMode: mode,
        groupRuleId: groupRuleId,
        groupTitle: groupTitle,
        clearGroup: mode != BrowseMode.group,
        clearTreePrefix: true,
        clearHiddenExtensions: mode != BrowseMode.group,
      ),
    );
    await _emitBrowseList();
  }

  Future<void> setFoldersView(bool enabled) async {
    await settings.setFoldersView(enabled);
    if (isClosed) return;
    emit(
      state.copyWith(
        foldersView: enabled,
        clearTreePrefix: !enabled,
      ),
    );
    await _emitBrowseList();
  }

  Future<void> openTreePrefix(String prefix) async {
    emit(state.copyWith(treePrefix: prefix));
    await _emitBrowseList();
  }

  Future<void> treeNavigateUp() async {
    final cur = state.treePrefix;
    if (cur.isEmpty) return;
    final parent = p.dirname(cur);
    final next = parent == '.' || parent == '/' ? '' : parent;
    emit(state.copyWith(treePrefix: next));
    await _emitBrowseList();
  }

  Future<void> toggleHiddenExtension(String extension) async {
    final ext = extension.trim().toLowerCase();
    if (ext.isEmpty) return;
    final next = Set<String>.from(state.hiddenExtensions);
    if (!next.add(ext)) next.remove(ext);
    emit(state.copyWith(hiddenExtensions: next));
    await _emitBrowseList();
  }

  Future<void> clearHiddenExtensions() async {
    emit(state.copyWith(clearHiddenExtensions: true));
    await _emitBrowseList();
  }

  Future<void> forceFullRescan() async {
    await scanner.invalidateDirCache();
    await refresh(forceFullScan: true, scopeToBrowseGroup: false);
  }

  Future<void> setDeviceAndSyncedOnly(bool value) async {
    emit(state.copyWith(deviceAndSyncedOnly: value));
    await _emitBrowseList();
  }

  /// Folder root for the active drawer group (optional nested [treePrefix]).
  List<Directory>? _browseGroupScanRoots() {
    if (state.browseMode != BrowseMode.group) return null;
    TrackingRule? groupRule;
    for (final r in state.rules) {
      if (r.id == state.groupRuleId) {
        groupRule = r;
        break;
      }
    }
    if (groupRule == null || groupRule.kind != TrackingRuleKind.folder) {
      return null;
    }
    var path = groupRule.patternOrUri;
    if (state.foldersView && state.treePrefix.isNotEmpty) {
      path = p.join(path, state.treePrefix);
    }
    return [Directory(path)];
  }

  /// Throttle progress UI updates so hashing/upload does not rebuild every chunk.
  void _emitIngestProgress(IngestFileProgress p) {
    if (isClosed) return;
    final now = DateTime.now();
    final prev = _lastIngestProgress;
    final phaseChanged =
        prev == null ||
        prev.phase != p.phase ||
        prev.index != p.index ||
        prev.total != p.total ||
        prev.title != p.title;
    final due = _lastIngestProgressEmit == null ||
        now.difference(_lastIngestProgressEmit!) >=
            const Duration(milliseconds: 200);
    final finishing = p.fraction >= 0.999;
    if (!phaseChanged && !due && !finishing) return;
    _lastIngestProgressEmit = now;
    _lastIngestProgress = p;
    emit(state.copyWith(ingestProgress: p));
  }

  Future<void> _emitBrowseList() async {
    List<CatalogFile> files;
    switch (state.browseMode) {
      case BrowseMode.allCatalog:
        files = applyDeviceSyncedFilter(
          _catalogFiles,
          enabled: state.deviceAndSyncedOnly,
        );
        final paths = await repository.mapPrimaryRelativePaths(
          files.map((f) => f.fileId),
        );
        files = [
          for (final f in files)
            f.copyWith(browsePath: paths[f.fileId] ?? f.title ?? f.fileId),
        ];
      case BrowseMode.group:
        final ids = await tracking.groupRuleIds(state.groupRuleId);
        final locals = await tracking.listLocalFiles(ruleIds: ids);
        files = await _localsToCatalogFiles(locals);
        TrackingRule? groupRule;
        for (final r in state.rules) {
          if (r.id == state.groupRuleId) {
            groupRule = r;
            break;
          }
        }
        final folderRoot = groupRule?.kind == TrackingRuleKind.folder
            ? groupRule!.patternOrUri
            : null;
        if (folderRoot != null) {
          final root = p.normalize(folderRoot);
          files = [
            for (final f in files)
              f.copyWith(
                browsePath: _relativeBrowsePath(f.browsePath, root),
              ),
          ];
        } else {
          // Strip shared absolute prefix so tree isn't storage/emulated/0/…
          files = _withStrippedCommonPrefix(files);
        }
      case BrowseMode.trackedOnDevice:
        files = await _localsToCatalogFiles(await tracking.listTracked());
        files = _withStrippedCommonPrefix(files);
      case BrowseMode.untrackedOnDevice:
        files = await _localsToCatalogFiles(await tracking.listUntracked());
        files = _withStrippedCommonPrefix(files);
      case BrowseMode.removedFromPc:
        files = await repository.listTombstonedFiles();
        final paths = await repository.mapPrimaryRelativePaths(
          files.map((f) => f.fileId),
        );
        files = [
          for (final f in files)
            f.copyWith(browsePath: paths[f.fileId] ?? f.title ?? f.fileId),
        ];
    }
    if (state.deviceAndSyncedOnly &&
        state.browseMode != BrowseMode.allCatalog &&
        state.browseMode != BrowseMode.removedFromPc) {
      files = files
          .where((f) => f.hasLocalBytes && !f.fileId.startsWith('local:'))
          .toList();
    }
    if (state.deviceAndSyncedOnly &&
        state.browseMode == BrowseMode.removedFromPc) {
      files = files.where((f) => f.hasLocalBytes).toList();
    }
    files = applyCatalogSearch(files, query: state.searchQuery);
    files = applyHiddenExtensions(
      files,
      hidden: state.hiddenExtensions,
    );
    if (isClosed) return;
    final preserve =
        state.viewState == CatalogViewState.error ||
        state.viewState == CatalogViewState.degraded;
    emit(
      state.copyWith(
        files: files,
        viewState: preserve
            ? state.viewState
            : (files.isEmpty
                ? CatalogViewState.empty
                : CatalogViewState.ready),
      ),
    );
  }

  Future<List<CatalogFile>> _localsToCatalogFiles(
    List<LocalTrackedFile> locals,
  ) async {
    final out = <CatalogFile>[];
    for (final local in locals) {
      if (local.isSynced && local.fileId != null) {
        final catalog = await repository.getFile(local.fileId!);
        if (catalog != null) {
          out.add(catalog.copyWith(browsePath: local.localPath));
          continue;
        }
      }
      final now = local.seenAt;
      final LocalUploadState? upload = switch (local.ingestStatus) {
        IngestStatus.pending => LocalUploadState.pending,
        IngestStatus.failed => LocalUploadState.failed,
        IngestStatus.synced || IngestStatus.untracked => null,
      };
      out.add(
        CatalogFile(
          fileId: local.fileId ?? 'local:${local.localPath}',
          contentHash: local.contentHash ?? 'pending',
          hashAlgo: 'blake3',
          mimeType: local.mimeType,
          sizeBytes: local.sizeBytes,
          title: local.title ?? p.basename(local.localPath),
          createdAt: now,
          updatedAt: now,
          availabilityMode: local.isSynced
              ? AvailabilityMode.pinned
              : AvailabilityMode.listed,
          hasLocalBytes: true,
          primarySourceKind: local.sourceKind,
          localUpload: upload,
          browsePath: local.localPath,
        ),
      );
    }
    return out;
  }

  String _relativeBrowsePath(String? absolute, String root) {
    final path = (absolute ?? '').replaceAll('\\', '/');
    final base = root.replaceAll('\\', '/');
    if (path.isEmpty) return '';
    if (path == base) return p.basename(path);
    if (path.startsWith('$base/')) {
      return path.substring(base.length + 1);
    }
    return p.basename(path);
  }

  List<CatalogFile> _withStrippedCommonPrefix(List<CatalogFile> files) {
    final paths = [
      for (final f in files)
        if (f.browsePath != null && f.browsePath!.isNotEmpty)
          f.browsePath!.replaceAll('\\', '/'),
    ];
    if (paths.length < 2) {
      return [
        for (final f in files)
          f.copyWith(
            browsePath: f.browsePath == null
                ? f.displayName
                : p.basename(f.browsePath!),
          ),
      ];
    }
    var prefix = paths.first;
    for (final path in paths.skip(1)) {
      while (prefix.isNotEmpty && !path.startsWith(prefix)) {
        final cut = prefix.lastIndexOf('/');
        prefix = cut <= 0 ? '' : prefix.substring(0, cut);
      }
      if (prefix.isEmpty) break;
    }
    // Keep prefix as a directory (drop trailing file segment if all share a dir).
    if (prefix.isNotEmpty && !prefix.endsWith('/')) {
      final asDir = paths.every(
        (path) => path == prefix || path.startsWith('$prefix/'),
      );
      if (!asDir) {
        final cut = prefix.lastIndexOf('/');
        prefix = cut <= 0 ? '' : prefix.substring(0, cut);
      }
    }
    if (prefix.isEmpty) {
      return [
        for (final f in files)
          f.copyWith(browsePath: p.basename(f.browsePath ?? f.displayName)),
      ];
    }
    final root = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    return [
      for (final f in files)
        f.copyWith(browsePath: _relativeBrowsePath(f.browsePath, root)),
    ];
  }

  Future<void> refresh({
    bool showSpinnerWhenEmpty = false,
    bool forceFullScan = false,
    bool scopeToBrowseGroup = true,
  }) async {
    if (_refreshBusy) {
      log.info('catalog', 'refresh ignored — already in progress');
      return;
    }
    _refreshBusy = true;
    try {
      await _refreshBody(
        showSpinnerWhenEmpty: showSpinnerWhenEmpty,
        forceFullScan: forceFullScan,
        scopeToBrowseGroup: scopeToBrowseGroup,
      );
    } finally {
      _refreshBusy = false;
    }
  }

  Future<void> _refreshBody({
    required bool showSpinnerWhenEmpty,
    required bool forceFullScan,
    required bool scopeToBrowseGroup,
  }) async {
    final showSpinner =
        showSpinnerWhenEmpty && state.files.isEmpty && !state.refreshing;
    emit(
      state.copyWith(
        refreshing: true,
        syncEnabled: settings.syncEnabled,
        viewState: showSpinner ? CatalogViewState.loading : state.viewState,
      ),
    );

    if (!settings.syncEnabled) {
      log.info('catalog', 'sync paused — local catalog only');
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(
          state.copyWith(
            refreshing: false,
            clearIngestProgress: true,
            statusMessage: 'Sync is off — showing local catalog only',
            viewState: files.isEmpty
                ? CatalogViewState.empty
                : CatalogViewState.degraded,
          ),
        );
      }
      await _emitBrowseList();
      return;
    }

    // Raise process to FG priority before any long work so Home during
    // scan/upload does not abort sockets.
    await backgroundIngest.ensureKeepAlive();

    void onIngest(IngestFileProgress p) {
      _emitIngestProgress(p);
      unawaited(backgroundIngest.updateKeepAliveProgress(p));
    }

    // Catalog delta only — uploads run via [backgroundIngest] so refresh
    // returns while hashing/upload continues (Android FG notification).
    final result = await sync.sync(
      onIngestProgress: onIngest,
      flushIngestQueue: false,
    );
    if (isClosed) return;

    await flushDeletionOutbox();
    if (isClosed) return;

    final limitRoots =
        scopeToBrowseGroup ? _browseGroupScanRoots() : null;
    if (limitRoots != null) {
      log.info(
        'catalog',
        'group scan → ${limitRoots.map((d) => d.path).join(", ")} '
        'force=$forceFullScan',
      );
    }

    try {
      await scanner.scanAndIngest(
        ingestMatches: false,
        forceFullScan: forceFullScan,
        limitRoots: limitRoots,
        onProgress: onIngest,
        onIndexed: () => _emitBrowseList(),
      );
    } catch (e) {
      log.warn('catalog', 'tracking scan failed: $e');
    }

    final files = await repository.listActiveFiles();
    _catalogFiles = files;
    if (result.ok) {
      log.info('catalog', 'refresh ok count=${files.length}');
      emit(
        state.copyWith(
          refreshing: false,
          clearStatusMessage: true,
        ),
      );
      await _emitBrowseList();
    } else {
      final err = result.error?.toString() ?? 'sync failed';
      log.warn('catalog', 'refresh degraded/error: $err');
      emit(
        state.copyWith(
          refreshing: false,
          statusMessage: err,
          viewState: files.isEmpty
              ? CatalogViewState.error
              : CatalogViewState.degraded,
        ),
      );
      await _emitBrowseList();
    }

    _kickBackgroundIngest();
  }

  void _kickBackgroundIngest() {
    unawaited(
      backgroundIngest.kick(
        onProgress: _emitIngestProgress,
        onFinished: () async {
          _lastIngestProgress = null;
          _lastIngestProgressEmit = null;
          if (isClosed) return;
          emit(state.copyWith(clearIngestProgress: true));
          final files = await repository.listActiveFiles();
          _catalogFiles = files;
          await _emitBrowseList();
        },
      ),
    );
  }

  /// Resume durable uploads after the app returns to the foreground.
  Future<void> onAppResumed() async {
    if (!settings.syncEnabled || isClosed) return;
    await flushDeletionOutbox();
    await backgroundIngest.recoverAfterResume();
    _kickBackgroundIngest();
  }

  Future<void> onRulesChanged() async {
    final rules = await tracking.listRules();
    if (!isClosed) emit(state.copyWith(rules: rules));
    await scanner.invalidateDirCache();
    if (!settings.syncEnabled) {
      await _emitBrowseList();
      return;
    }
    try {
      await scanner.scanAndIngest(
        ingestMatches: false,
        forceFullScan: true,
        onProgress: (p) {
          _emitIngestProgress(p);
          unawaited(backgroundIngest.updateKeepAliveProgress(p));
        },
        onIndexed: () => _emitBrowseList(),
      );
    } catch (e) {
      log.warn('catalog', 'tracking scan failed: $e');
    }
    await _emitBrowseList();
    _kickBackgroundIngest();
  }

  Future<String?> pinFile(
    String fileId, {
    String? destinationDir,
    String? fileName,
  }) async {
    if (fileId.startsWith('local:')) {
      return 'Sync this file first (pending ingest)';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      await pinService.bringToPhone(
        fileId,
        destination: PinDestination(
          directory: destinationDir,
          fileName: fileName,
        ),
      );
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'pin failed: $e');
      if (!isClosed) {
        emit(
          state.copyWith(
            clearBusyFileId: true,
            statusMessage: e.toString(),
          ),
        );
      }
      return e.toString();
    }
  }

  /// Keep listing on phone catalog; delete local bytes (PC retains the blob).
  /// Tombstoned files: local-only discard (no availability API).
  Future<String?> removeFromDevice(String fileId) async {
    if (fileId.startsWith('local:')) {
      return 'Not a catalog file';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      final file = await repository.getFile(fileId);
      if (file == null) {
        return 'file not found';
      }
      if (file.isDeleted) {
        await repository.discardLocalBytes(file);
      } else {
        await pinService.keepOnPcOnly(fileId);
      }
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'remove from device failed: $e');
      if (!isClosed) {
        emit(
          state.copyWith(
            clearBusyFileId: true,
            statusMessage: e.toString(),
          ),
        );
      }
      return e.toString();
    }
  }

  /// Alias: keep PC catalog listing; drop local bytes.
  Future<String?> keepOnPcOnly(String fileId) => removeFromDevice(fileId);

  Future<String?> unpinFile(String fileId) => removeFromDevice(fileId);

  /// Soft-delete on the PC; drops local listing + unreferenced pin bytes.
  ///
  /// When offline / degraded, queues the DELETE and applies an optimistic
  /// local tombstone immediately (same local byte discard as online).
  Future<String?> deleteFromPc(String fileId) async {
    if (fileId.startsWith('local:')) {
      return 'Not on the PC yet — sync first or remove the tracking rule';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      final local = await repository.getFile(fileId);
      if (local == null) {
        if (!isClosed) emit(state.copyWith(clearBusyFileId: true));
        return 'file not found';
      }

      try {
        final tombstoned = await api.deleteFile(fileId);
        await repository.applyTombstone(tombstoned);
        await deletionOutbox.removeByFileId(fileId);
      } on HomesyncApiException catch (e) {
        if (e.statusCode == 404) {
          await repository.forgetLocalFile(fileId);
          await deletionOutbox.removeByFileId(fileId);
        } else {
          await _queueOptimisticPcDelete(local);
          await _emitPendingDeletionIds();
          final files = await repository.listActiveFiles();
          _catalogFiles = files;
          if (!isClosed) {
            emit(
              state.copyWith(
                clearBusyFileId: true,
                statusMessage:
                    'Queued — will remove on PC when online',
              ),
            );
          }
          await _emitBrowseList();
          return null;
        }
      } catch (_) {
        await _queueOptimisticPcDelete(local);
        await _emitPendingDeletionIds();
        final files = await repository.listActiveFiles();
        _catalogFiles = files;
        if (!isClosed) {
          emit(
            state.copyWith(
              clearBusyFileId: true,
              statusMessage: 'Queued — will remove on PC when online',
            ),
          );
        }
        await _emitBrowseList();
        return null;
      }

      await _emitPendingDeletionIds();
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'delete from PC failed: $e');
      if (!isClosed) {
        emit(
          state.copyWith(
            clearBusyFileId: true,
            statusMessage: e.toString(),
          ),
        );
      }
      return e.toString();
    }
  }

  Future<void> _queueOptimisticPcDelete(CatalogFile local) async {
    await deletionOutbox.enqueue(
      fileId: local.fileId,
      title: local.title,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await repository.applyTombstone(
      local.copyWith(deletedAt: now, updatedAt: now),
    );
    log.info('catalog', 'queued PC delete ${local.fileId}');
  }

  /// Flush pending PC soft-deletes. Safe to call when online again.
  Future<int> flushDeletionOutbox() async {
    final items = await deletionOutbox.list();
    if (items.isEmpty) {
      await _emitPendingDeletionIds();
      return 0;
    }
    var flushed = 0;
    for (final item in items) {
      try {
        final tombstoned = await api.deleteFile(item.fileId);
        await repository.applyTombstone(tombstoned);
        await deletionOutbox.remove(item.id);
        flushed += 1;
      } on HomesyncApiException catch (e) {
        if (e.statusCode == 404) {
          await repository.forgetLocalFile(item.fileId);
          await deletionOutbox.remove(item.id);
          flushed += 1;
        } else {
          log.warn(
            'catalog',
            'deletion flush deferred ${item.fileId}: $e',
          );
        }
      } catch (e) {
        log.warn('catalog', 'deletion flush deferred ${item.fileId}: $e');
      }
    }
    await _emitPendingDeletionIds();
    if (flushed > 0) {
      _catalogFiles = await repository.listActiveFiles();
      await _emitBrowseList();
    }
    return flushed;
  }

  Future<void> _emitPendingDeletionIds() async {
    final ids = await deletionOutbox.pendingFileIds();
    if (!isClosed) emit(state.copyWith(pendingDeletionIds: ids));
  }

  /// Replace tags on a catalog file (online). Updates local mirror from server ids.
  Future<String?> setFileTags(String fileId, List<String> tags) async {
    if (fileId.startsWith('local:')) {
      return 'Sync this file first (pending ingest)';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      final updated = await api.putFileTags(fileId: fileId, tags: tags);
      final allTags = await api.listTags();
      final desiredLower = {
        for (final n in updated.tags) n.toLowerCase(),
      };
      final matched = allTags
          .where((t) => desiredLower.contains(t.name.toLowerCase()))
          .toList();
      // Preserve FileOut order when possible.
      matched.sort((a, b) {
        final ia = updated.tags.indexWhere(
          (n) => n.toLowerCase() == a.name.toLowerCase(),
        );
        final ib = updated.tags.indexWhere(
          (n) => n.toLowerCase() == b.name.toLowerCase(),
        );
        return ia.compareTo(ib);
      });
      await repository.replaceFileTags(
        fileId: fileId,
        tags: matched,
        updatedAt: updated.updatedAt,
      );
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'set tags failed: $e');
      if (!isClosed) {
        emit(
          state.copyWith(
            clearBusyFileId: true,
            statusMessage: e.toString(),
          ),
        );
      }
      return e.toString();
    }
  }

  Future<List<String>> listTagSuggestions() async {
    final tags = await repository.listAllTags();
    return tags.map((t) => t.name).toList();
  }

  /// Drop a local tombstone / leftover catalog row without a server call.
  /// Cancels a pending PC deletion outbox row for this id.
  Future<String?> forgetLocalFile(String fileId) async {
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      await deletionOutbox.removeByFileId(fileId);
      await repository.forgetLocalFile(fileId);
      await _emitPendingDeletionIds();
      _catalogFiles = await repository.listActiveFiles();
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'forget local failed: $e');
      if (!isClosed) {
        emit(
          state.copyWith(
            clearBusyFileId: true,
            statusMessage: e.toString(),
          ),
        );
      }
      return e.toString();
    }
  }

  /// Clear all local Removed-from-PC rows (phone-only).
  Future<String?> forgetAllTombstones() async {
    emit(state.copyWith(clearStatusMessage: true));
    try {
      final tombstoned = await repository.listTombstonedFiles();
      for (final f in tombstoned) {
        await deletionOutbox.removeByFileId(f.fileId);
      }
      final n = await repository.forgetAllTombstones();
      await _emitPendingDeletionIds();
      _catalogFiles = await repository.listActiveFiles();
      if (!isClosed) {
        emit(
          state.copyWith(
            statusMessage: n == 0
                ? 'No removed items to clear'
                : 'Forgot $n removed item${n == 1 ? '' : 's'}',
          ),
        );
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'forget all tombstones failed: $e');
      if (!isClosed) {
        emit(state.copyWith(statusMessage: e.toString()));
      }
      return e.toString();
    }
  }

  /// Toggle "bound to server": PC tombstone also deletes local pin bytes.
  Future<String?> setBoundToServer(String fileId, {required bool bound}) async {
    if (fileId.startsWith('local:')) {
      return 'Pin this file first';
    }
    final file = await repository.getFile(fileId);
    if (file == null) return 'file not found';
    if (!file.isPinned) {
      return 'Bound to server is only available for pinned files';
    }
    try {
      await repository.setBoundToServer(fileId, bound: bound);
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'bound to server failed: $e');
      return e.toString();
    }
  }

  /// Returns local bytes when materialised; null if listed-only / missing.
  Future<Uint8List?> openLocalBytes(CatalogFile file) {
    return pinService.openLocalBytes(file);
  }

  /// Absolute on-device path (origin or pin store), if bytes are present.
  Future<String?> resolveLocalPath(CatalogFile file) {
    return pinService.resolveLocalPath(file);
  }

  /// Catalog relative path from mirrored provenance, if any.
  Future<String?> catalogRelativePath(CatalogFile file) {
    return repository.primaryRelativePath(file.fileId);
  }

  /// Open with the system viewer (Android ACTION_VIEW via FileProvider).
  Future<String?> openWithSystem(CatalogFile file) async {
    final path = await resolveLocalPath(file);
    if (path == null) {
      return 'No local file path';
    }
    try {
      final result = await OpenFilex.open(path, type: file.mimeType);
      if (result.type == ResultType.done) return null;
      return result.message;
    } catch (e) {
      log.warn('catalog', 'open with system failed: $e');
      return e.toString();
    }
  }

  /// Convenience: decode UTF-8 text preview when bytes are present.
  Future<String?> openLocalTextPreview(CatalogFile file, {int maxChars = 4000}) async {
    final bytes = await openLocalBytes(file);
    if (bytes == null) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }

  Future<List<KdbxConflict>> listKdbxConflicts({String? state = 'active'}) {
    return api.listConflicts(state: state);
  }

  Future<String?> setKdbxSecret(String fileId, String password) async {
    try {
      await api.putKdbxSecret(fileId, password);
      return null;
    } catch (e) {
      log.warn('catalog', 'kdbx secret failed: $e');
      return e.toString();
    }
  }

  Future<Object?> recheckKdbxConflict(String conflictId) async {
    try {
      return await api.recheckConflict(conflictId);
    } catch (e) {
      log.warn('catalog', 'kdbx recheck failed: $e');
      return e.toString();
    }
  }

  Future<String?> resolveKdbxConflictRequest({
    required String conflictId,
    required String fileId,
    required KdbxResolveRequest request,
  }) async {
    try {
      final updated = await api.resolveConflict(conflictId, request);
      await repository.upsertFile(updated);
      final all = await tracking.listTracked();
      for (final row in all) {
        if (row.fileId == fileId) {
          await tracking.markSynced(
            localPath: row.localPath,
            fileId: updated.fileId,
            contentHash: updated.contentHash,
            sizeBytes: updated.sizeBytes,
          );
        }
      }
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'kdbx resolve failed: $e');
      return e.toString();
    }
  }

  /// Hash + upload a resolved vault, then close the outbox.
  Future<String?> resolveKdbxConflictWithFile({
    required String conflictId,
    required String fileId,
    required String path,
  }) async {
    try {
      final source = File(path);
      if (!await source.exists()) return 'file missing';
      final size = await source.length();
      final hash = await ContentHash.blake3File(source);
      await api.putBlobResumable(
        algo: ContentHash.algo,
        hexHash: hash,
        contentLength: size,
        readAt: (offset, length) async {
          final raf = await source.open();
          try {
            await raf.setPosition(offset);
            return await raf.read(length);
          } finally {
            await raf.close();
          }
        },
      );
      return resolveKdbxConflictRequest(
        conflictId: conflictId,
        fileId: fileId,
        request: KdbxResolveRequest.upload(
          contentHash: hash,
          sizeBytes: size,
          note: 'merged on phone',
        ),
      );
    } catch (e) {
      log.warn('catalog', 'kdbx resolve failed: $e');
      return e.toString();
    }
  }

  @override
  Future<void> close() async {
    settings.removeListener(_onSettingsChanged);
    await _filesSub?.cancel();
    await _rulesSub?.cancel();
    return super.close();
  }
}
