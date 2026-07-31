import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:injectable/injectable.dart';

enum CatalogViewState { loading, empty, ready, error, degraded }

final class CatalogState extends Equatable {
  const CatalogState({
    this.viewState = CatalogViewState.loading,
    this.files = const [],
    this.statusMessage,
    this.refreshing = false,
  });

  final CatalogViewState viewState;
  final List<CatalogFile> files;
  final String? statusMessage;
  final bool refreshing;

  CatalogState copyWith({
    CatalogViewState? viewState,
    List<CatalogFile>? files,
    String? statusMessage,
    bool clearStatusMessage = false,
    bool? refreshing,
  }) {
    return CatalogState(
      viewState: viewState ?? this.viewState,
      files: files ?? this.files,
      statusMessage:
          clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      refreshing: refreshing ?? this.refreshing,
    );
  }

  @override
  List<Object?> get props => [viewState, files, statusMessage, refreshing];
}

/// Catalog UI state: watches local Drift rows + drives delta refresh.
@injectable
class CatalogCubit extends Cubit<CatalogState> {
  CatalogCubit({
    required this.repository,
    required this.sync,
    required this.log,
  }) : super(const CatalogState()) {
    _filesSub = repository.watchActiveFiles().listen(_onFiles);
  }

  final CatalogRepository repository;
  final CatalogSync sync;
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

  @override
  Future<void> close() async {
    await _filesSub?.cancel();
    return super.close();
  }
}
