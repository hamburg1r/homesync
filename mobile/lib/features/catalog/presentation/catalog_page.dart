import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_view.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/catalog/presentation/ingest_progress_banner.dart';
import 'package:homesync_mobile/features/catalog/presentation/kdbx_conflicts_sheet.dart';
import 'package:homesync_mobile/features/catalog/presentation/pin_destination_dialog.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_sheet.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(context.read<CatalogCubit>().onAppResumed());
    }
  }

  Future<void> _openSettings(BuildContext context) async {
    final cubit = context.read<CatalogCubit>();
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SettingsSheet(
        settings: widget.settings,
        tracking: getIt<TrackingRepository>(),
        scanner: getIt<DeviceScanner>(),
        onRulesChanged: () => cubit.onRulesChanged(),
        currentDeviceId: cubit.currentDeviceId,
        onListDevices: cubit.listServerDevices,
        onReclaimDevice: cubit.reclaimDeviceId,
        onResetDevice: cubit.resetDeviceId,
      ),
    );
    if (changed == true) {
      await cubit.refresh(showSpinnerWhenEmpty: true);
    }
  }

  Future<void> _openConflicts(BuildContext context) async {
    final cubit = context.read<CatalogCubit>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => KdbxConflictsSheet(cubit: cubit),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CatalogCubit, CatalogState>(
      // Ingest progress updates a banner only — rebuilding the file list (and
      // restarting thumb FutureBuilders) every chunk caused heavy frame skips.
      buildWhen: (previous, current) =>
          previous.viewState != current.viewState ||
          previous.files != current.files ||
          previous.statusMessage != current.statusMessage ||
          previous.busyFileId != current.busyFileId ||
          previous.browseMode != current.browseMode ||
          previous.groupRuleId != current.groupRuleId ||
          previous.groupTitle != current.groupTitle ||
          previous.deviceAndSyncedOnly != current.deviceAndSyncedOnly ||
          previous.rules != current.rules ||
          previous.searchQuery != current.searchQuery ||
          previous.syncEnabled != current.syncEnabled ||
          previous.refreshing != current.refreshing ||
          previous.foldersView != current.foldersView ||
          previous.treePrefix != current.treePrefix ||
          previous.hiddenExtensions != current.hiddenExtensions ||
          previous.pendingDeletionIds != current.pendingDeletionIds,
      builder: (context, state) {
        return CatalogBrowseView(
          state: state.viewState,
          files: state.files,
          statusMessage: state.statusMessage,
          busyFileId: state.busyFileId,
          pendingDeletionIds: state.pendingDeletionIds,
          browseMode: state.browseMode,
          groupRuleId: state.groupRuleId,
          groupTitle: state.groupTitle,
          deviceAndSyncedOnly: state.deviceAndSyncedOnly,
          rules: state.rules,
          searchQuery: state.searchQuery,
          syncEnabled: state.syncEnabled,
          foldersView: state.foldersView,
          treePrefix: state.treePrefix,
          hiddenExtensions: state.hiddenExtensions,
          progressBanner: BlocSelector<CatalogCubit, CatalogState,
              IngestFileProgress?>(
            selector: (s) => s.ingestProgress,
            builder: (context, progress) {
              if (progress == null) return const SizedBox.shrink();
              return IngestProgressBanner(progress: progress);
            },
          ),
          onRefresh: () => context.read<CatalogCubit>().refresh(
                forceFullScan: true,
              ),
          onOpenSettings: () => _openSettings(context),
          onOpenConflicts: () => _openConflicts(context),
          onForceRescan: () => context.read<CatalogCubit>().forceFullRescan(),
          onPin: (file) => _bringToPhone(context, file),
          onUnpin: (file) =>
              context.read<CatalogCubit>().removeFromDevice(file.fileId),
          onDeleteFromPc: (file) =>
              context.read<CatalogCubit>().deleteFromPc(file.fileId),
          onForgetLocal: (file) =>
              context.read<CatalogCubit>().forgetLocalFile(file.fileId),
          onClearRemoved: () =>
              context.read<CatalogCubit>().forgetAllTombstones(),
          onBoundToServer: (file, bound) => context
              .read<CatalogCubit>()
              .setBoundToServer(file.fileId, bound: bound),
          onSetTags: (file, tags) =>
              context.read<CatalogCubit>().setFileTags(file.fileId, tags),
          onTagSuggestions: () =>
              context.read<CatalogCubit>().listTagSuggestions(),
          onOpen: (file) => _openFile(context, file),
          onResolveLocalPath: (file) =>
              context.read<CatalogCubit>().resolveLocalPath(file),
          onCatalogRelativePath: (file) =>
              context.read<CatalogCubit>().catalogRelativePath(file),
          onSelectBrowse: (mode, {ruleId, title}) => context
              .read<CatalogCubit>()
              .setBrowseMode(mode, groupRuleId: ruleId, groupTitle: title),
          onToggleDeviceSynced: (v) =>
              context.read<CatalogCubit>().setDeviceAndSyncedOnly(v),
          onSearchChanged: (q) =>
              context.read<CatalogCubit>().setSearchQuery(q),
          onLoadThumb: (file) =>
              context.read<CatalogCubit>().thumbService.ensureThumb(file),
          onSetFoldersView: (v) =>
              context.read<CatalogCubit>().setFoldersView(v),
          onOpenTreePrefix: (prefix) =>
              context.read<CatalogCubit>().openTreePrefix(prefix),
          onTreeNavigateUp: () =>
              context.read<CatalogCubit>().treeNavigateUp(),
          onToggleHiddenExtension: (ext) =>
              context.read<CatalogCubit>().toggleHiddenExtension(ext),
          onClearHiddenExtensions: () =>
              context.read<CatalogCubit>().clearHiddenExtensions(),
        );
      },
    );
  }

  Future<String?> _bringToPhone(BuildContext context, CatalogFile file) async {
    final cubit = context.read<CatalogCubit>();
    // Already on device (origin / prior pin) — just flip availability.
    if (file.hasLocalBytes) {
      return cubit.pinFile(file.fileId);
    }
    final choice = await showDialog<PinDestChoice>(
      context: context,
      builder: (context) => PinDestinationDialog(
        file: file,
        initialDir: cubit.settings.pinDestinationDir,
      ),
    );
    if (choice == null) return 'cancelled';
    if (!context.mounted) return 'cancelled';
    return cubit.pinFile(
      file.fileId,
      destinationDir: choice.directory,
      fileName: choice.fileName,
    );
  }

  Future<void> _openFile(BuildContext context, CatalogFile file) async {
    final cubit = context.read<CatalogCubit>();
    if (!file.hasLocalBytes) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(file.displayName),
          content: const Text(
            'This file is listed only — no bytes on this device. '
            'Bring to phone to download from the PC.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final err = await cubit.openWithSystem(file);
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }
}
