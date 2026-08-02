import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/thumb_service.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';
import 'package:injectable/injectable.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

enum CatalogViewState { loading, empty, ready, error, degraded }

final class CatalogState extends Equatable {
  const CatalogState({
    this.viewState = CatalogViewState.loading,
    this.files = const [],
    this.statusMessage,
    this.refreshing = false,
    this.busyFileId,
    this.browseMode = BrowseMode.allCatalog,
    this.groupRuleId,
    this.groupTitle,
    this.deviceAndSyncedOnly = false,
    this.rules = const [],
    this.searchQuery = '',
    this.syncEnabled = true,
    this.ingestProgress,
  });

  final CatalogViewState viewState;
  final List<CatalogFile> files;
  final String? statusMessage;
  final bool refreshing;
  final String? busyFileId;
  final BrowseMode browseMode;
  final String? groupRuleId;
  final String? groupTitle;
  final bool deviceAndSyncedOnly;
  final List<TrackingRule> rules;
  final String searchQuery;
  final bool syncEnabled;
  final IngestFileProgress? ingestProgress;

  CatalogState copyWith({
    CatalogViewState? viewState,
    List<CatalogFile>? files,
    String? statusMessage,
    bool clearStatusMessage = false,
    bool? refreshing,
    String? busyFileId,
    bool clearBusyFileId = false,
    BrowseMode? browseMode,
    String? groupRuleId,
    bool clearGroup = false,
    String? groupTitle,
    bool? deviceAndSyncedOnly,
    List<TrackingRule>? rules,
    String? searchQuery,
    bool? syncEnabled,
    IngestFileProgress? ingestProgress,
    bool clearIngestProgress = false,
  }) {
    return CatalogState(
      viewState: viewState ?? this.viewState,
      files: files ?? this.files,
      statusMessage:
          clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      refreshing: refreshing ?? this.refreshing,
      busyFileId: clearBusyFileId ? null : (busyFileId ?? this.busyFileId),
      browseMode: browseMode ?? this.browseMode,
      groupRuleId: clearGroup ? null : (groupRuleId ?? this.groupRuleId),
      groupTitle: clearGroup ? null : (groupTitle ?? this.groupTitle),
      deviceAndSyncedOnly: deviceAndSyncedOnly ?? this.deviceAndSyncedOnly,
      rules: rules ?? this.rules,
      searchQuery: searchQuery ?? this.searchQuery,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      ingestProgress: clearIngestProgress
          ? null
          : (ingestProgress ?? this.ingestProgress),
    );
  }

  @override
  List<Object?> get props => [
        viewState,
        files,
        statusMessage,
        refreshing,
        busyFileId,
        browseMode,
        groupRuleId,
        groupTitle,
        deviceAndSyncedOnly,
        rules,
        searchQuery,
        syncEnabled,
        ingestProgress,
      ];
}

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
    required this.settings,
    required this.log,
  }) : super(CatalogState(syncEnabled: settings.syncEnabled)) {
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
  final SettingsStore settings;
  final AppLog log;
  StreamSubscription<List<CatalogFile>>? _filesSub;
  StreamSubscription<List<TrackingRule>>? _rulesSub;
  List<CatalogFile> _catalogFiles = const [];
  bool _started = false;

  void _onSettingsChanged() {
    if (isClosed) return;
    if (state.syncEnabled != settings.syncEnabled) {
      emit(state.copyWith(syncEnabled: settings.syncEnabled));
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    log.info('catalog', 'cubit start');
    final rules = await tracking.listRules();
    if (!isClosed) {
      emit(state.copyWith(rules: rules, syncEnabled: settings.syncEnabled));
    }
    await refresh(showSpinnerWhenEmpty: true);
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
    final filtered = _applySearch(_applyDeviceSyncedFilter(files));
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

  List<CatalogFile> _applyDeviceSyncedFilter(List<CatalogFile> files) {
    if (!state.deviceAndSyncedOnly) return files;
    return files.where((f) => f.hasLocalBytes && !f.isDeleted).toList();
  }

  /// Local catalog search (title / notes / tags). Server ``?q=`` is for API clients.
  List<CatalogFile> _applySearch(List<CatalogFile> files) {
    final needle = state.searchQuery.trim().toLowerCase();
    if (needle.isEmpty) return files;
    return files.where((f) {
      if (f.displayName.toLowerCase().contains(needle)) return true;
      if ((f.notes ?? '').toLowerCase().contains(needle)) return true;
      return f.tags.any((t) => t.toLowerCase().contains(needle));
    }).toList();
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
      ),
    );
    await _emitBrowseList();
  }

  Future<void> setDeviceAndSyncedOnly(bool value) async {
    emit(state.copyWith(deviceAndSyncedOnly: value));
    await _emitBrowseList();
  }

  Future<void> _emitBrowseList() async {
    List<CatalogFile> files;
    switch (state.browseMode) {
      case BrowseMode.allCatalog:
        files = _applyDeviceSyncedFilter(_catalogFiles);
      case BrowseMode.group:
        final locals = await tracking.listLocalFiles(ruleId: state.groupRuleId);
        files = await _localsToCatalogFiles(locals);
      case BrowseMode.trackedOnDevice:
        files = await _localsToCatalogFiles(await tracking.listTracked());
      case BrowseMode.untrackedOnDevice:
        files = await _localsToCatalogFiles(await tracking.listUntracked());
    }
    if (state.deviceAndSyncedOnly && state.browseMode != BrowseMode.allCatalog) {
      files = files
          .where((f) => f.hasLocalBytes && !f.fileId.startsWith('local:'))
          .toList();
    }
    files = _applySearch(files);
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
      if (local.fileId != null) {
        final catalog = await repository.getFile(local.fileId!);
        if (catalog != null) {
          out.add(catalog);
          continue;
        }
      }
      final now = local.seenAt;
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
        ),
      );
    }
    return out;
  }

  Future<void> refresh({bool showSpinnerWhenEmpty = false}) async {
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

    void onIngest(IngestFileProgress p) {
      if (!isClosed) emit(state.copyWith(ingestProgress: p));
    }

    final result = await sync.sync(onIngestProgress: onIngest);
    if (isClosed) return;

    // Scan + ingest when rules exist (no-op if empty); one file at a time.
    try {
      await scanner.scanAndIngest(onProgress: onIngest);
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
          clearIngestProgress: true,
        ),
      );
      await _emitBrowseList();
    } else {
      final err = result.error?.toString() ?? 'sync failed';
      log.warn('catalog', 'refresh degraded/error: $err');
      emit(
        state.copyWith(
          refreshing: false,
          clearIngestProgress: true,
          statusMessage: err,
          viewState: files.isEmpty
              ? CatalogViewState.error
              : CatalogViewState.degraded,
        ),
      );
      await _emitBrowseList();
    }
  }

  Future<void> onRulesChanged() async {
    final rules = await tracking.listRules();
    if (!isClosed) emit(state.copyWith(rules: rules));
    if (!settings.syncEnabled) {
      await _emitBrowseList();
      return;
    }
    try {
      await scanner.scanAndIngest(
        onProgress: (p) {
          if (!isClosed) emit(state.copyWith(ingestProgress: p));
        },
      );
    } finally {
      if (!isClosed) emit(state.copyWith(clearIngestProgress: true));
    }
    await _emitBrowseList();
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
  Future<String?> keepOnPcOnly(String fileId) async {
    if (fileId.startsWith('local:')) {
      return 'Not a catalog file';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      await pinService.keepOnPcOnly(fileId);
      final files = await repository.listActiveFiles();
      _catalogFiles = files;
      if (!isClosed) {
        emit(state.copyWith(clearBusyFileId: true));
      }
      await _emitBrowseList();
      return null;
    } catch (e) {
      log.warn('catalog', 'keep on PC only failed: $e');
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

  Future<String?> unpinFile(String fileId) => keepOnPcOnly(fileId);

  /// Soft-delete on the PC; drops local listing + unreferenced pin bytes.
  Future<String?> deleteFromPc(String fileId) async {
    if (fileId.startsWith('local:')) {
      return 'Not on the PC yet — sync first or remove the tracking rule';
    }
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      final tombstoned = await api.deleteFile(fileId);
      await repository.applyTombstone(tombstoned);
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

  @override
  Future<void> close() async {
    settings.removeListener(_onSettingsChanged);
    await _filesSub?.cancel();
    await _rulesSub?.cancel();
    return super.close();
  }
}
