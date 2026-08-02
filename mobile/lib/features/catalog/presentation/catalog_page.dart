import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_sheet.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key, required this.settings});

  final SettingsStore settings;

  Future<void> _openSettings(BuildContext context) async {
    final cubit = context.read<CatalogCubit>();
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SettingsSheet(
        settings: settings,
        tracking: getIt<TrackingRepository>(),
        onRulesChanged: () => cubit.onRulesChanged(),
      ),
    );
    if (changed == true) {
      await cubit.refresh(showSpinnerWhenEmpty: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CatalogCubit, CatalogState>(
      builder: (context, state) {
        return CatalogBrowseView(
          state: state.viewState,
          files: state.files,
          statusMessage: state.statusMessage,
          busyFileId: state.busyFileId,
          browseMode: state.browseMode,
          groupRuleId: state.groupRuleId,
          groupTitle: state.groupTitle,
          deviceAndSyncedOnly: state.deviceAndSyncedOnly,
          rules: state.rules,
          onRefresh: () => context.read<CatalogCubit>().refresh(),
          onOpenSettings: () => _openSettings(context),
          onPin: (file) => context.read<CatalogCubit>().pinFile(file.fileId),
          onUnpin: (file) => context.read<CatalogCubit>().unpinFile(file.fileId),
          onOpen: (file) => _openFile(context, file),
          onSelectBrowse: (mode, {ruleId, title}) => context
              .read<CatalogCubit>()
              .setBrowseMode(mode, groupRuleId: ruleId, groupTitle: title),
          onToggleDeviceSynced: (v) =>
              context.read<CatalogCubit>().setDeviceAndSyncedOnly(v),
        );
      },
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
            'Pin it to download from the PC.',
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

    final preview = await cubit.openLocalTextPreview(file);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.displayName),
        content: SingleChildScrollView(
          child: Text(
            preview ??
                'Pinned locally (${_formatBytes(file.sizeBytes)}). '
                    'Binary preview not shown.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

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
    this.onRefresh,
    this.onOpenSettings,
    this.onPin,
    this.onUnpin,
    this.onOpen,
    this.onSelectBrowse,
    this.onToggleDeviceSynced,
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
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<void> Function(CatalogFile file)? onOpen;
  final void Function(
    BrowseMode mode, {
    String? ruleId,
    String? title,
  })? onSelectBrowse;
  final ValueChanged<bool>? onToggleDeviceSynced;

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
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'Browse',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              SwitchListTile(
                title: const Text('On this device & synced'),
                subtitle: const Text('Hide listed-only / pending'),
                value: deviceAndSyncedOnly,
                onChanged: onToggleDeviceSynced,
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('All (catalog)'),
                selected: browseMode == BrowseMode.allCatalog,
                onTap: () {
                  onSelectBrowse?.call(BrowseMode.allCatalog);
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Tracked on device'),
                selected: browseMode == BrowseMode.trackedOnDevice,
                onTap: () {
                  onSelectBrowse?.call(BrowseMode.trackedOnDevice);
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('Untracked'),
                selected: browseMode == BrowseMode.untrackedOnDevice,
                onTap: () {
                  onSelectBrowse?.call(BrowseMode.untrackedOnDevice);
                  Navigator.pop(context);
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Groups',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (rules.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('No tracking rules yet'),
                  subtitle: Text('Add regex or folder rules in Settings'),
                )
              else
                ...rules.map(
                  (rule) => ListTile(
                    leading: Icon(
                      rule.kind == TrackingRuleKind.folder
                          ? Icons.folder_outlined
                          : Icons.pattern,
                    ),
                    title: Text(rule.name),
                    subtitle: Text(
                      rule.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: browseMode == BrowseMode.group &&
                        groupRuleId == rule.id,
                    onTap: () {
                      onSelectBrowse?.call(
                        BrowseMode.group,
                        ruleId: rule.id,
                        title: rule.name,
                      );
                      Navigator.pop(context);
                    },
                  ),
                ),
              const Divider(),
              if (onOpenSettings != null)
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(context);
                    onOpenSettings!();
                  },
                ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (state == CatalogViewState.degraded && statusMessage != null)
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
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (state) {
      case CatalogViewState.loading:
        return const Center(child: CircularProgressIndicator());
      case CatalogViewState.error:
        return _MessagePane(
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
                child: _MessagePane(
                  icon: Icons.folder_open_outlined,
                  title: 'No files yet',
                  subtitle: browseMode == BrowseMode.allCatalog
                      ? 'Index a library on the PC, then pull to refresh. '
                          'Or add tracking rules in Settings to upload from this phone.'
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
              return _FileTile(
                file: file,
                busy: busyFileId == file.fileId,
                onPin: onPin,
                onUnpin: onUnpin,
                onOpen: onOpen,
              );
            },
          ),
        );
    }
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.file,
    required this.busy,
    this.onPin,
    this.onUnpin,
    this.onOpen,
  });

  final CatalogFile file;
  final bool busy;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<void> Function(CatalogFile file)? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeLabel = file.mimeType ?? 'unknown type';
    final sizeLabel = _formatBytes(file.sizeBytes);
    final tags = file.tags.isEmpty ? 'no tags' : file.tags.join(', ');
    final modeLabel = file.availabilityMode.wire;
    final chipColor = file.isPinned
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return ListTile(
      leading: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _iconForMime(file.mimeType),
              color: theme.colorScheme.primary,
            ),
      title: Text(file.displayName),
      subtitle: Text('$typeLabel · $sizeLabel · $tags'),
      isThreeLine: true,
      trailing: Chip(
        label: Text(modeLabel),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        backgroundColor: chipColor,
      ),
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          builder: (sheetContext) => _FileDetailSheet(
            file: file,
            busy: busy,
            onPin: onPin,
            onUnpin: onUnpin,
            onOpen: onOpen,
          ),
        );
      },
    );
  }
}

class _FileDetailSheet extends StatelessWidget {
  const _FileDetailSheet({
    required this.file,
    required this.busy,
    this.onPin,
    this.onUnpin,
    this.onOpen,
  });

  final CatalogFile file;
  final bool busy;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<void> Function(CatalogFile file)? onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(file.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('Availability: ${file.availabilityMode.wire}'
              '${file.hasLocalBytes ? " · bytes on device" : " · metadata only"}'),
          Text('Type: ${file.mimeType ?? "unknown"}'),
          Text('Size: ${_formatBytes(file.sizeBytes)}'),
          Text('Hash: ${file.hashAlgo}:${file.contentHash}'),
          if (file.tags.isNotEmpty) Text('Tags: ${file.tags.join(", ")}'),
          if (file.notes != null && file.notes!.isNotEmpty)
            Text('Notes: ${file.notes}'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (file.hasLocalBytes && onOpen != null)
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await onOpen!(file);
                        },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open'),
                ),
              if (!file.isPinned &&
                  onPin != null &&
                  !file.fileId.startsWith('local:'))
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final err = await onPin!(file);
                          if (context.mounted) {
                            Navigator.pop(context);
                            if (err != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(err)),
                              );
                            }
                          }
                        },
                  icon: const Icon(Icons.push_pin_outlined),
                  label: const Text('Pin'),
                ),
              if (file.isPinned && onUnpin != null)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final err = await onUnpin!(file);
                          if (context.mounted) {
                            Navigator.pop(context);
                            if (err != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(err)),
                              );
                            }
                          }
                        },
                  icon: const Icon(Icons.push_pin),
                  label: const Text('Unpin'),
                ),
              if (!file.hasLocalBytes)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Listed only — cannot open offline'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessagePane extends StatelessWidget {
  const _MessagePane({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
            if (secondaryLabel != null && onSecondary != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _iconForMime(String? mime) {
  if (mime == null) return Icons.insert_drive_file_outlined;
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('text/')) return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}
