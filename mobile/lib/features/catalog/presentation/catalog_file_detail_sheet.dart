import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_format.dart';

class CatalogFileDetailSheet extends StatefulWidget {
  const CatalogFileDetailSheet({
    super.key,
    required this.file,
    required this.busy,
    this.onPin,
    this.onUnpin,
    this.onDeleteFromPc,
    this.onBoundToServer,
    this.onOpen,
    this.localPathFuture,
    this.catalogPathFuture,
  });

  final CatalogFile file;
  final bool busy;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  final Future<void> Function(CatalogFile file)? onOpen;
  final Future<String?>? localPathFuture;
  final Future<String?>? catalogPathFuture;

  @override
  State<CatalogFileDetailSheet> createState() => _CatalogFileDetailSheetState();
}

class _CatalogFileDetailSheetState extends State<CatalogFileDetailSheet> {
  late bool _bound;
  bool _bindingBusy = false;

  @override
  void initState() {
    super.initState();
    _bound = widget.file.boundToServer;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from PC?'),
        content: Text(
          'Soft-delete “${widget.file.displayName}” on the server. '
          'It leaves the main catalog and appears under Removed from PC. '
          'Blob GC is not run yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final err = await widget.onDeleteFromPc!(widget.file);
    if (context.mounted) {
      Navigator.pop(context);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  Future<void> _setBound(bool value) async {
    final cb = widget.onBoundToServer;
    if (cb == null) return;
    setState(() => _bindingBusy = true);
    final err = await cb(widget.file, value);
    if (!mounted) return;
    setState(() {
      _bindingBusy = false;
      if (err == null) _bound = value;
    });
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final busy = widget.busy;
    final bringLabel = file.isGhost ? 'Bring to phone' : 'Pin';
    final canDeleteFromPc = widget.onDeleteFromPc != null &&
        !file.isDeleted &&
        !file.fileId.startsWith('local:');
    final showBoundToggle =
        file.isPinned && !file.isDeleted && widget.onBoundToServer != null;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.displayName, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (file.provenanceSubtitle != null)
                Text(
                  file.provenanceSubtitle!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              Text(
                file.isDeleted
                    ? 'Removed from PC'
                        '${file.hasLocalBytes ? " · bytes on device" : " · metadata only"}'
                    : file.isUploadPending
                        ? 'Pending upload to PC · on device'
                        : file.isUploadFailed
                            ? 'Upload failed · on device'
                            : 'Availability: ${file.availabilityMode.wire}'
                                '${file.hasLocalBytes ? " · bytes on device" : " · metadata only"}',
              ),
              Text('Type: ${file.mimeType ?? "unknown"}'),
              Text('Size: ${formatCatalogBytes(file.sizeBytes)}'),
              if (widget.localPathFuture != null)
                FutureBuilder<String?>(
                  future: widget.localPathFuture,
                  builder: (context, snapshot) {
                    final path = snapshot.data;
                    if (path == null || path.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return SelectableText(
                      'Path: $path',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  },
                ),
              if (widget.catalogPathFuture != null)
                FutureBuilder<String?>(
                  future: widget.catalogPathFuture,
                  builder: (context, snapshot) {
                    final path = snapshot.data;
                    if (path == null || path.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return SelectableText(
                      'Catalog path: $path',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  },
                ),
              Text('Hash: ${file.hashAlgo}:${file.contentHash}'),
              if (file.tags.isNotEmpty) Text('Tags: ${file.tags.join(", ")}'),
              if (file.notes != null && file.notes!.isNotEmpty)
                Text('Notes: ${file.notes}'),
              if (showBoundToggle) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bound to server'),
                  subtitle: const Text(
                    'Delete this pin if the PC removes the file',
                  ),
                  value: _bound,
                  onChanged: (busy || _bindingBusy) ? null : _setBound,
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (file.hasLocalBytes && widget.onOpen != null)
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              Navigator.pop(context);
                              await widget.onOpen!(file);
                            },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open'),
                    ),
                  if (!file.isDeleted &&
                      !file.isPinned &&
                      widget.onPin != null &&
                      !file.fileId.startsWith('local:'))
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final err = await widget.onPin!(file);
                              if (!context.mounted) return;
                              if (err == 'cancelled') return;
                              Navigator.pop(context);
                              if (err != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(err)),
                                );
                              }
                            },
                      icon: Icon(
                        file.isGhost
                            ? Icons.download_outlined
                            : Icons.push_pin_outlined,
                      ),
                      label: Text(bringLabel),
                    ),
                  if (!file.isDeleted &&
                      file.hasLocalBytes &&
                      widget.onUnpin != null &&
                      !file.fileId.startsWith('local:'))
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Keep on PC only?'),
                                  content: Text(
                                    'Remove “${file.displayName}” from this device. '
                                    'The PC catalog copy stays. Local files at the '
                                    'origin or download path will be deleted.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Remove from device'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true || !context.mounted) return;
                              final err = await widget.onUnpin!(file);
                              if (context.mounted) {
                                Navigator.pop(context);
                                if (err != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(err)),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.phonelink_erase_outlined),
                      label: const Text('Keep on PC only'),
                    ),
                  if (file.isDeleted &&
                      file.hasLocalBytes &&
                      widget.onUnpin != null)
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Remove from device?'),
                                  content: Text(
                                    'Delete local bytes for “${file.displayName}”. '
                                    'It stays under Removed from PC as metadata only.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Remove from device'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true || !context.mounted) return;
                              final err = await widget.onUnpin!(file);
                              if (context.mounted) {
                                Navigator.pop(context);
                                if (err != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(err)),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.phonelink_erase_outlined),
                      label: const Text('Remove from device'),
                    ),
                  if (canDeleteFromPc)
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _confirmDelete(context),
                      icon: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      label: Text(
                        'Remove from PC',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (file.isDeleted && !file.hasLocalBytes)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Removed from PC — metadata only'),
                    )
                  else if (file.isUploadPending)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Pending upload — will sync to PC soon',
                      ),
                    )
                  else if (file.isUploadFailed)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Upload failed — pull to refresh to retry',
                      ),
                    )
                  else if (!file.hasLocalBytes)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Listed only — cannot open offline'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
