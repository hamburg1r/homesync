import 'package:equatable/equatable.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

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
