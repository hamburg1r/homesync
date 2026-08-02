import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:injectable/injectable.dart';

enum CatalogViewState { loading, empty, ready, error, degraded }

final class CatalogState extends Equatable {
  const CatalogState({
    this.viewState = CatalogViewState.loading,
    this.files = const [],
    this.statusMessage,
    this.refreshing = false,
    this.busyFileId,
  });

  final CatalogViewState viewState;
  final List<CatalogFile> files;
  final String? statusMessage;
  final bool refreshing;
  final String? busyFileId;

  CatalogState copyWith({
    CatalogViewState? viewState,
    List<CatalogFile>? files,
    String? statusMessage,
    bool clearStatusMessage = false,
    bool? refreshing,
    String? busyFileId,
    bool clearBusyFileId = false,
  }) {
    return CatalogState(
      viewState: viewState ?? this.viewState,
      files: files ?? this.files,
      statusMessage:
          clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      refreshing: refreshing ?? this.refreshing,
      busyFileId: clearBusyFileId ? null : (busyFileId ?? this.busyFileId),
    );
  }

  @override
  List<Object?> get props =>
      [viewState, files, statusMessage, refreshing, busyFileId];
}

/// Catalog UI state: watches local Drift rows + drives delta refresh / pin.
@injectable
class CatalogCubit extends Cubit<CatalogState> {
  CatalogCubit({
    required this.repository,
    required this.sync,
    required this.pinService,
    required this.log,
  }) : super(const CatalogState()) {
    _filesSub = repository.watchActiveFiles().listen(_onFiles);
  }

  final CatalogRepository repository;
  final CatalogSync sync;
  final PinService pinService;
  final AppLog log;
  StreamSubscription<List<CatalogFile>>? _filesSub;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    log.info('catalog', 'cubit start');
    await refresh(showSpinnerWhenEmpty: true);
  }

  void _onFiles(List<CatalogFile> files) {
    if (isClosed) return;
    final syncing = state.refreshing;
    if (syncing) {
      emit(state.copyWith(files: files));
      return;
    }
    if (state.viewState == CatalogViewState.error ||
        state.viewState == CatalogViewState.degraded) {
      emit(state.copyWith(files: files));
      return;
    }
    emit(
      state.copyWith(
        files: files,
        viewState:
            files.isEmpty ? CatalogViewState.empty : CatalogViewState.ready,
        clearStatusMessage: true,
      ),
    );
  }

  Future<void> refresh({bool showSpinnerWhenEmpty = false}) async {
    final showSpinner =
        showSpinnerWhenEmpty && state.files.isEmpty && !state.refreshing;
    emit(
      state.copyWith(
        refreshing: true,
        viewState: showSpinner ? CatalogViewState.loading : state.viewState,
      ),
    );

    final result = await sync.sync();
    if (isClosed) return;

    final files = await repository.listActiveFiles();
    if (result.ok) {
      log.info('catalog', 'refresh ok count=${files.length}');
      emit(
        state.copyWith(
          refreshing: false,
          files: files,
          viewState:
              files.isEmpty ? CatalogViewState.empty : CatalogViewState.ready,
          clearStatusMessage: true,
        ),
      );
    } else {
      final err = result.error?.toString() ?? 'sync failed';
      log.warn('catalog', 'refresh degraded/error: $err');
      emit(
        state.copyWith(
          refreshing: false,
          files: files,
          statusMessage: err,
          viewState: files.isEmpty
              ? CatalogViewState.error
              : CatalogViewState.degraded,
        ),
      );
    }
  }

  Future<String?> pinFile(String fileId) async {
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      await pinService.pin(fileId);
      final files = await repository.listActiveFiles();
      if (!isClosed) {
        emit(
          state.copyWith(
            files: files,
            clearBusyFileId: true,
            viewState: files.isEmpty
                ? CatalogViewState.empty
                : CatalogViewState.ready,
          ),
        );
      }
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

  Future<String?> unpinFile(String fileId) async {
    emit(state.copyWith(busyFileId: fileId, clearStatusMessage: true));
    try {
      await pinService.unpin(fileId);
      final files = await repository.listActiveFiles();
      if (!isClosed) {
        emit(
          state.copyWith(
            files: files,
            clearBusyFileId: true,
            viewState: files.isEmpty
                ? CatalogViewState.empty
                : CatalogViewState.ready,
          ),
        );
      }
      return null;
    } catch (e) {
      log.warn('catalog', 'unpin failed: $e');
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

  /// Returns local bytes when materialised; null if listed-only / missing.
  Future<Uint8List?> openLocalBytes(CatalogFile file) {
    return pinService.openLocalBytes(file);
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
    await _filesSub?.cancel();
    return super.close();
  }
}
