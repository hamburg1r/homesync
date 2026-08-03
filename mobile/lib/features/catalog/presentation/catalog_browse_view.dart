import 'dart:io';

import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_drawer.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_file_tile.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_message_pane.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_search_field.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_state.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

/// Presentational catalog browse UI (list + pin affordance + drawer).
class CatalogBrowseView extends StatelessWidget {
  const CatalogBrowseView({
    super.key,
    required this.state,
    required this.files,
    this.statusMessage,
    this.busyFileId,
    this.browseMode = BrowseMode.allCatalog,
    this.groupRuleId,
    this.groupTitle,
    this.deviceAndSyncedOnly = false,
    this.rules = const [],
    this.searchQuery = '',
    this.syncEnabled = true,
    this.progressBanner,
    this.onRefresh,
    this.onOpenSettings,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onBoundToServer,
    this.onOpen,
    this.onResolveLocalPath,
    this.onCatalogRelativePath,
    this.onSelectBrowse,
    this.onToggleDeviceSynced,
    this.onSearchChanged,
    this.onLoadThumb,
  });

  final CatalogViewState state;
  final List<CatalogFile> files;
  final String? statusMessage;
  final String? busyFileId;
  final BrowseMode browseMode;
  final String? groupRuleId;
  final String? groupTitle;
  final bool deviceAndSyncedOnly;
  final List<TrackingRule> rules;
  final String searchQuery;
  final bool syncEnabled;
  final Widget? progressBanner;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  final Future<void> Function(CatalogFile file)? onOpen;
  final Future<String?> Function(CatalogFile file)? onResolveLocalPath;
  final Future<String?> Function(CatalogFile file)? onCatalogRelativePath;
  final void Function(
    BrowseMode mode, {
    String? ruleId,
    String? title,
  })? onSelectBrowse;
  final ValueChanged<bool>? onToggleDeviceSynced;
  final ValueChanged<String>? onSearchChanged;
  final Future<File?> Function(CatalogFile file)? onLoadThumb;

  String get _title {
    switch (browseMode) {
      case BrowseMode.allCatalog:
        return 'Homesync';
      case BrowseMode.group:
        return groupTitle ?? 'Group';
      case BrowseMode.trackedOnDevice:
        return 'Tracked on device';
      case BrowseMode.untrackedOnDevice:
        return 'Untracked';
      case BrowseMode.removedFromPc:
        return 'Removed from PC';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (onOpenSettings != null)
            IconButton(
              tooltip: 'Server settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      drawer: CatalogBrowseDrawer(
        browseMode: browseMode,
        groupRuleId: groupRuleId,
        deviceAndSyncedOnly: deviceAndSyncedOnly,
        rules: rules,
        onSelectBrowse: onSelectBrowse,
        onToggleDeviceSynced: onToggleDeviceSynced,
        onOpenSettings: onOpenSettings,
      ),
      body: Column(
        children: [
          if (onSearchChanged != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: CatalogSearchField(
                query: searchQuery,
                onChanged: onSearchChanged!,
              ),
            ),
          ?progressBanner,
          if (!syncEnabled)
            MaterialBanner(
              content: Text(
                statusMessage ??
                    'Sync is off — pull to refresh only reloads the local catalog.',
              ),
              leading: const Icon(Icons.sync_disabled),
              actions: [
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Settings'),
                ),
              ],
            )
          else if (state == CatalogViewState.degraded && statusMessage != null)
            MaterialBanner(
              content: Text(
                'Showing local catalog (offline/degraded): $statusMessage',
              ),
              leading: const Icon(Icons.cloud_off_outlined),
              actions: [
                TextButton(
                  onPressed: onRefresh == null ? null : () => onRefresh!(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(child: _CatalogBrowseBody(
            state: state,
            files: files,
            statusMessage: statusMessage,
            busyFileId: busyFileId,
            browseMode: browseMode,
            onRefresh: onRefresh,
            onOpenSettings: onOpenSettings,
            onPin: onPin,
            onUnpin: onUnpin,
            onDeleteFromPc: onDeleteFromPc,
            onBoundToServer: onBoundToServer,
            onOpen: onOpen,
            onResolveLocalPath: onResolveLocalPath,
            onCatalogRelativePath: onCatalogRelativePath,
            onLoadThumb: onLoadThumb,
          )),
        ],
      ),
    );
  }
}

class _CatalogBrowseBody extends StatelessWidget {
  const _CatalogBrowseBody({
    required this.state,
    required this.files,
    this.statusMessage,
    this.busyFileId,
    required this.browseMode,
    this.onRefresh,
    this.onOpenSettings,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onBoundToServer,
    this.onOpen,
    this.onResolveLocalPath,
    this.onCatalogRelativePath,
    this.onLoadThumb,
  });

  final CatalogViewState state;
  final List<CatalogFile> files;
  final String? statusMessage;
  final String? busyFileId;
  final BrowseMode browseMode;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  final Future<void> Function(CatalogFile file)? onOpen;
  final Future<String?> Function(CatalogFile file)? onResolveLocalPath;
  final Future<String?> Function(CatalogFile file)? onCatalogRelativePath;
  final Future<File?> Function(CatalogFile file)? onLoadThumb;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case CatalogViewState.loading:
        return const Center(child: CircularProgressIndicator());
      case CatalogViewState.error:
        return CatalogMessagePane(
          icon: Icons.error_outline,
          title: 'Could not reach catalog',
          subtitle: statusMessage ?? 'Check server URL and network.',
          actionLabel: 'Retry',
          onAction: onRefresh == null ? null : () => onRefresh!(),
          secondaryLabel: 'Settings',
          onSecondary: onOpenSettings,
        );
      case CatalogViewState.empty:
        return RefreshIndicator(
          onRefresh: onRefresh ?? () async {},
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.5,
                child: CatalogMessagePane(
                  icon: Icons.folder_open_outlined,
                  title: 'No files yet',
                  subtitle: browseMode == BrowseMode.allCatalog
                      ? 'Index a library on the PC, then pull to refresh. '
                          'Or add tracking rules in Settings to upload from this phone.'
                      : browseMode == BrowseMode.removedFromPc
                          ? 'No soft-deleted files in the local catalog. '
                              'Remove from PC (or delete on the server) to see them here.'
                          : 'Nothing in this view. Pull to refresh or change drawer filter.',
                  actionLabel: 'Sync now',
                  onAction: onRefresh == null ? null : () => onRefresh!(),
                ),
              ),
            ],
          ),
        );
      case CatalogViewState.ready:
      case CatalogViewState.degraded:
        return RefreshIndicator(
          onRefresh: onRefresh ?? () async {},
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: files.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final file = files[index];
              return CatalogFileTile(
                file: file,
                busy: busyFileId == file.fileId,
                onPin: onPin,
                onUnpin: onUnpin,
                onDeleteFromPc: onDeleteFromPc,
                onBoundToServer: onBoundToServer,
                onOpen: onOpen,
                onResolveLocalPath: onResolveLocalPath,
                onCatalogRelativePath: onCatalogRelativePath,
                onLoadThumb: onLoadThumb,
              );
            },
          ),
        );
    }
  }
}
