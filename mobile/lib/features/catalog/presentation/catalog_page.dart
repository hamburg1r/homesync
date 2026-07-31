import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_sheet.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key, required this.settings});

  final SettingsStore settings;

  Future<void> _openSettings(BuildContext context) async {
    final cubit = context.read<CatalogCubit>();
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SettingsSheet(settings: settings),
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
          onRefresh: () => context.read<CatalogCubit>().refresh(),
          onOpenSettings: () => _openSettings(context),
        );
      },
    );
  }
}

/// Presentational catalog browse UI (list-only; no blob open).
class CatalogBrowseView extends StatelessWidget {
  const CatalogBrowseView({
    super.key,
    required this.state,
    required this.files,
    this.statusMessage,
    this.onRefresh,
    this.onOpenSettings,
  });

  final CatalogViewState state;
  final List<CatalogFile> files;
  final String? statusMessage;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Homesync'),
        actions: [
          if (onOpenSettings != null)
            IconButton(
              tooltip: 'Server settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
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
                  subtitle:
                      'Index a library on the PC, then pull to refresh. '
                      'Listings are metadata-only — opening full files is not required.',
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
              return _FileTile(file: file);
            },
          ),
        );
    }
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file});

  final CatalogFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeLabel = file.mimeType ?? 'unknown type';
    final sizeLabel = _formatBytes(file.sizeBytes);
    final tags = file.tags.isEmpty ? 'no tags' : file.tags.join(', ');

    return ListTile(
      leading: Icon(
        _iconForMime(file.mimeType),
        color: theme.colorScheme.primary,
      ),
      title: Text(file.displayName),
      subtitle: Text('$typeLabel · $sizeLabel · $tags'),
      isThreeLine: true,
      trailing: Chip(
        label: const Text('listed'),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          builder: (context) => _FileDetailSheet(file: file),
        );
      },
    );
  }
}

class _FileDetailSheet extends StatelessWidget {
  const _FileDetailSheet({required this.file});

  final CatalogFile file;

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
          const Text('Availability: listed (metadata only)'),
          Text('Type: ${file.mimeType ?? "unknown"}'),
          Text('Size: ${_formatBytes(file.sizeBytes)}'),
          Text('Hash: ${file.hashAlgo}:${file.contentHash}'),
          if (file.tags.isNotEmpty) Text('Tags: ${file.tags.join(", ")}'),
          if (file.notes != null && file.notes!.isNotEmpty)
            Text('Notes: ${file.notes}'),
          const SizedBox(height: 12),
          Text(
            'Full file open / pin download lands in a later milestone.',
            style: Theme.of(context).textTheme.bodySmall,
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
