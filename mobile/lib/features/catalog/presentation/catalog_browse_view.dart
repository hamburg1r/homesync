import 'dart:io';

import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_drawer.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_tree.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_file_tile.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_message_pane.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_search_field.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_state.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:path/path.dart' as p;

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
    this.foldersView = false,
    this.treePrefix = '',
    this.hiddenExtensions = const {},
    this.progressBanner,
    this.onRefresh,
    this.onOpenSettings,
    this.onOpenConflicts,
    this.onForceRescan,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onForgetLocal,
    this.onClearRemoved,
    this.onBoundToServer,
    this.onSetTags,
    this.onTagSuggestions,
    this.onOpen,
    this.onResolveLocalPath,
    this.onCatalogRelativePath,
    this.onSelectBrowse,
    this.onToggleDeviceSynced,
    this.onSearchChanged,
    this.onLoadThumb,
    this.onSetFoldersView,
    this.onOpenTreePrefix,
    this.onTreeNavigateUp,
    this.onToggleHiddenExtension,
    this.onClearHiddenExtensions,
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
  final bool foldersView;
  final String treePrefix;
  final Set<String> hiddenExtensions;
  final Widget? progressBanner;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenConflicts;
  final Future<void> Function()? onForceRescan;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file)? onForgetLocal;
  final Future<String?> Function()? onClearRemoved;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  final Future<String?> Function(CatalogFile file, List<String> tags)? onSetTags;
  final Future<List<String>> Function()? onTagSuggestions;
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
  final ValueChanged<bool>? onSetFoldersView;
  final ValueChanged<String>? onOpenTreePrefix;
  final VoidCallback? onTreeNavigateUp;
  final ValueChanged<String>? onToggleHiddenExtension;
  final VoidCallback? onClearHiddenExtensions;

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
    final extChoices = extensionsInFiles(files);
    // Include currently hidden so toggles remain visible after hide.
    final extMenu = {...extChoices, ...hiddenExtensions}.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (browseMode == BrowseMode.removedFromPc &&
              onClearRemoved != null &&
              files.isNotEmpty)
            IconButton(
              tooltip: 'Clear removed list',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Clear removed list?'),
                    content: const Text(
                      'Forget all soft-deleted catalog rows on this phone. '
                      'Does not run PC garbage collection. A full re-sync may '
                      'bring back rows still soft-deleted on the server.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await onClearRemoved!();
              },
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          PopupMenuButton<_AppMenuAction>(
            tooltip: 'Menu',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) async {
              switch (action) {
                case _AppMenuAction.settings:
                  onOpenSettings?.call();
                case _AppMenuAction.conflicts:
                  onOpenConflicts?.call();
                case _AppMenuAction.flatView:
                  onSetFoldersView?.call(false);
                case _AppMenuAction.foldersView:
                  onSetFoldersView?.call(true);
                case _AppMenuAction.forceRescan:
                  await onForceRescan?.call();
                case _AppMenuAction.clearHidden:
                  onClearHiddenExtensions?.call();
              }
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: _AppMenuAction.flatView,
                checked: !foldersView,
                child: const Text('Flat file list'),
              ),
              CheckedPopupMenuItem(
                value: _AppMenuAction.foldersView,
                checked: foldersView,
                child: const Text('Folders'),
              ),
              if (browseMode == BrowseMode.group && extMenu.isNotEmpty) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                  enabled: false,
                  child: Text('Hide extensions (view only)'),
                ),
                for (final ext in extMenu)
                  CheckedPopupMenuItem(
                    value: null,
                    checked: hiddenExtensions.contains(ext),
                    enabled: true,
                    child: Text('Hide .$ext'),
                    onTap: () {
                      // Popup closes before onTap; schedule after frame.
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        onToggleHiddenExtension?.call(ext);
                      });
                    },
                  ),
                if (hiddenExtensions.isNotEmpty)
                  const PopupMenuItem(
                    value: _AppMenuAction.clearHidden,
                    child: Text('Show all extensions'),
                  ),
              ],
              const PopupMenuDivider(),
              if (onForceRescan != null)
                const PopupMenuItem(
                  value: _AppMenuAction.forceRescan,
                  child: Text('Force full rescan'),
                ),
              if (onOpenConflicts != null)
                const PopupMenuItem(
                  value: _AppMenuAction.conflicts,
                  child: Text('KeePass conflicts'),
                ),
              if (onOpenSettings != null)
                const PopupMenuItem(
                  value: _AppMenuAction.settings,
                  child: Text('Settings'),
                ),
            ],
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
        onOpenConflicts: onOpenConflicts,
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
          if (browseMode == BrowseMode.group && extMenu.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final ext in extMenu)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text('.$ext'),
                        selected: hiddenExtensions.contains(ext),
                        onSelected: (_) => onToggleHiddenExtension?.call(ext),
                        tooltip: hiddenExtensions.contains(ext)
                            ? 'Show .$ext'
                            : 'Hide .$ext',
                      ),
                    ),
                ],
              ),
            ),
          if (foldersView && treePrefix.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_upward),
              title: Text(p.basename(treePrefix)),
              subtitle: Text(treePrefix),
              onTap: onTreeNavigateUp,
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
          Expanded(
            child: _CatalogBrowseBody(
              state: state,
              files: files,
              statusMessage: statusMessage,
              busyFileId: busyFileId,
              browseMode: browseMode,
              foldersView: foldersView,
              treePrefix: treePrefix,
              onRefresh: onRefresh,
              onOpenSettings: onOpenSettings,
              onPin: onPin,
              onUnpin: onUnpin,
              onDeleteFromPc: onDeleteFromPc,
              onForgetLocal: onForgetLocal,
              onBoundToServer: onBoundToServer,
              onSetTags: onSetTags,
              onTagSuggestions: onTagSuggestions,
              onOpen: onOpen,
              onResolveLocalPath: onResolveLocalPath,
              onCatalogRelativePath: onCatalogRelativePath,
              onLoadThumb: onLoadThumb,
              onOpenTreePrefix: onOpenTreePrefix,
            ),
          ),
        ],
      ),
    );
  }
}

enum _AppMenuAction {
  settings,
  conflicts,
  flatView,
  foldersView,
  forceRescan,
  clearHidden,
}

class _CatalogBrowseBody extends StatelessWidget {
  const _CatalogBrowseBody({
    required this.state,
    required this.files,
    this.statusMessage,
    this.busyFileId,
    required this.browseMode,
    required this.foldersView,
    required this.treePrefix,
    this.onRefresh,
    this.onOpenSettings,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onForgetLocal,
    this.onBoundToServer,
    this.onSetTags,
    this.onTagSuggestions,
    this.onOpen,
    this.onResolveLocalPath,
    this.onCatalogRelativePath,
    this.onLoadThumb,
    this.onOpenTreePrefix,
  });

  final CatalogViewState state;
  final List<CatalogFile> files;
  final String? statusMessage;
  final String? busyFileId;
  final BrowseMode browseMode;
  final bool foldersView;
  final String treePrefix;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file)? onForgetLocal;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  final Future<String?> Function(CatalogFile file, List<String> tags)? onSetTags;
  final Future<List<String>> Function()? onTagSuggestions;
  final Future<void> Function(CatalogFile file)? onOpen;
  final Future<String?> Function(CatalogFile file)? onResolveLocalPath;
  final Future<String?> Function(CatalogFile file)? onCatalogRelativePath;
  final Future<File?> Function(CatalogFile file)? onLoadThumb;
  final ValueChanged<String>? onOpenTreePrefix;

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
        if (!foldersView) {
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
                  onForgetLocal: onForgetLocal,
                  onBoundToServer: onBoundToServer,
                  onSetTags: onSetTags,
                  onTagSuggestions: onTagSuggestions,
                  onOpen: onOpen,
                  onResolveLocalPath: onResolveLocalPath,
                  onCatalogRelativePath: onCatalogRelativePath,
                  onLoadThumb: onLoadThumb,
                );
              },
            ),
          );
        }

        final rows = buildTreeRows(files: files, treePrefix: treePrefix);
        return RefreshIndicator(
          onRefresh: onRefresh ?? () async {},
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = rows[index];
              switch (row) {
                case CatalogTreeFolderRow(
                    :final name,
                    :final prefix,
                    :final fileCount,
                    :final pendingCount,
                    :final hasPending,
                  ):
                  return ListTile(
                    leading: hasPending
                        ? const SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          )
                        : const Icon(Icons.folder_outlined),
                    title: Text(name),
                    subtitle: Text(
                      hasPending
                          ? '$fileCount files · $pendingCount uploading'
                          : '$fileCount files',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onOpenTreePrefix?.call(prefix),
                  );
                case CatalogTreeFileRow(:final file):
                  return CatalogFileTile(
                    file: file,
                    busy: busyFileId == file.fileId,
                    onPin: onPin,
                    onUnpin: onUnpin,
                    onDeleteFromPc: onDeleteFromPc,
                    onForgetLocal: onForgetLocal,
                    onBoundToServer: onBoundToServer,
                    onSetTags: onSetTags,
                    onTagSuggestions: onTagSuggestions,
                    onOpen: onOpen,
                    onResolveLocalPath: onResolveLocalPath,
                    onCatalogRelativePath: onCatalogRelativePath,
                    onLoadThumb: onLoadThumb,
                  );
              }
            },
          ),
        );
    }
  }
}
