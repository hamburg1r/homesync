import 'dart:io';

import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_file_detail_sheet.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_format.dart';

class CatalogFileTile extends StatelessWidget {
  const CatalogFileTile({
    super.key,
    required this.file,
    required this.busy,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onBoundToServer,
    this.onOpen,
    this.onResolveLocalPath,
    this.onCatalogRelativePath,
    this.onLoadThumb,
  });

  final CatalogFile file;
  final bool busy;
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
    final theme = Theme.of(context);
    final typeLabel = file.mimeType ?? 'unknown type';
    final sizeLabel = formatCatalogBytes(file.sizeBytes);
    final tags = file.tags.isEmpty ? 'no tags' : file.tags.join(', ');
    final modeLabel = file.statusLabel();
    final chipColor = file.isDeleted || file.isUploadFailed
        ? theme.colorScheme.errorContainer
        : file.isUploadPending
            ? theme.colorScheme.tertiaryContainer
            : file.isPinned
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest;
    final provenance = file.provenanceSubtitle;
    final subtitle = provenance == null
        ? '$typeLabel · $sizeLabel · $tags'
        : '$provenance\n$typeLabel · $sizeLabel · $tags';

    return ListTile(
      leading: busy
          ? const SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : CatalogThumbOrIcon(file: file, onLoadThumb: onLoadThumb),
      title: Text(file.displayName),
      subtitle: Text(subtitle),
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
          isScrollControlled: true,
          builder: (sheetContext) => CatalogFileDetailSheet(
            file: file,
            busy: busy,
            onPin: onPin,
            onUnpin: onUnpin,
            onDeleteFromPc: onDeleteFromPc,
            onBoundToServer: onBoundToServer,
            onOpen: onOpen,
            localPathFuture: onResolveLocalPath?.call(file),
            catalogPathFuture: onCatalogRelativePath?.call(file),
          ),
        );
      },
    );
  }
}

class CatalogThumbOrIcon extends StatelessWidget {
  const CatalogThumbOrIcon({super.key, required this.file, this.onLoadThumb});

  final CatalogFile file;
  final Future<File?> Function(CatalogFile file)? onLoadThumb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Icon(
      catalogIconForMime(file.mimeType),
      color: theme.colorScheme.primary,
    );
    if (!file.canShowThumb || onLoadThumb == null) {
      return SizedBox(width: 40, height: 40, child: Center(child: fallback));
    }
    return FutureBuilder<File?>(
      future: onLoadThumb!(file),
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              path,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
          );
        }
        return SizedBox(width: 40, height: 40, child: Center(child: fallback));
      },
    );
  }
}
