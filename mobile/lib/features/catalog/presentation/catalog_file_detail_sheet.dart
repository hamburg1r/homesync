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
    this.onForgetLocal,
    this.onBoundToServer,
    this.onSetTags,
    this.onTagSuggestions,
    this.onOpen,
    this.localPathFuture,
    this.catalogPathFuture,
  });

  final CatalogFile file;
  final bool busy;
  final Future<String?> Function(CatalogFile file)? onPin;
  final Future<String?> Function(CatalogFile file)? onUnpin;
  final Future<String?> Function(CatalogFile file)? onDeleteFromPc;
  final Future<String?> Function(CatalogFile file)? onForgetLocal;
  final Future<String?> Function(CatalogFile file, bool bound)? onBoundToServer;
  /// Replace tags on the file (full list). Returns error string or null.
  final Future<String?> Function(CatalogFile file, List<String> tags)? onSetTags;
  final Future<List<String>> Function()? onTagSuggestions;
  final Future<void> Function(CatalogFile file)? onOpen;
  final Future<String?>? localPathFuture;
  final Future<String?>? catalogPathFuture;

  @override
  State<CatalogFileDetailSheet> createState() => _CatalogFileDetailSheetState();
}

class _CatalogFileDetailSheetState extends State<CatalogFileDetailSheet> {
  late bool _bound;
  bool _bindingBusy = false;
  late List<String> _tags;
  bool _tagsBusy = false;
  final _tagController = TextEditingController();
  List<String> _suggestions = const [];

  bool get _canEditTags =>
      widget.onSetTags != null &&
      !widget.file.isDeleted &&
      !widget.file.isUploadPending &&
      !widget.file.isUploadFailed &&
      !widget.file.fileId.startsWith('local:');

  @override
  void initState() {
    super.initState();
    _bound = widget.file.boundToServer;
    _tags = List<String>.from(widget.file.tags);
    if (_canEditTags && widget.onTagSuggestions != null) {
      widget.onTagSuggestions!().then((names) {
        if (mounted) setState(() => _suggestions = names);
      });
    }
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _applyTags(List<String> next) async {
    final cb = widget.onSetTags;
    if (cb == null || _tagsBusy) return;
    final normalized = _normalizeTags(next);
    setState(() {
      _tagsBusy = true;
      _tags = normalized;
    });
    final err = await cb(widget.file, normalized);
    if (!mounted) return;
    setState(() => _tagsBusy = false);
    if (err != null) {
      setState(() => _tags = List<String>.from(widget.file.tags));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  static List<String> _normalizeTags(List<String> raw) {
    final out = <String>[];
    final seen = <String>{};
    for (final r in raw) {
      final name = r.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(name);
    }
    return out;
  }

  Future<void> _addTagFromField() async {
    final name = _tagController.text.trim();
    if (name.isEmpty) return;
    _tagController.clear();
    await _applyTags([..._tags, name]);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from PC?'),
        content: Text(
          'Soft-delete “${widget.file.displayName}” on the server. '
          'It leaves the main catalog and appears under Removed from PC. '
          'Run GC on the PC later to hard-purge and free blob space.',
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

  Future<void> _confirmForget(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget on this phone?'),
        content: Text(
          'Remove “${widget.file.displayName}” from the local Removed list. '
          'Does not change the PC catalog. Sync after PC GC also clears these.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final err = await widget.onForgetLocal!(widget.file);
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

  Widget _buildTagsSection(BuildContext context) {
    final busy = widget.busy || _tagsBusy;
    if (!_canEditTags) {
      if (_tags.isEmpty) return const SizedBox.shrink();
      return Text('Tags: ${_tags.join(", ")}');
    }
    final unusedSuggestions = _suggestions
        .where(
          (s) => !_tags.any((t) => t.toLowerCase() == s.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tags', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final tag in _tags)
              InputChip(
                label: Text(tag),
                onDeleted: busy
                    ? null
                    : () => _applyTags(_tags.where((t) => t != tag).toList()),
              ),
            if (_tags.isEmpty)
              Text(
                'No tags',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tagController,
                enabled: !busy,
                decoration: const InputDecoration(
                  hintText: 'Add tag',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addTagFromField(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: busy ? null : _addTagFromField,
              icon: const Icon(Icons.add),
              tooltip: 'Add tag',
            ),
          ],
        ),
        if (unusedSuggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final name in unusedSuggestions.take(8))
                ActionChip(
                  label: Text(name),
                  onPressed: busy
                      ? null
                      : () => _applyTags([..._tags, name]),
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final busy = widget.busy || _tagsBusy;
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
              const SizedBox(height: 8),
              _buildTagsSection(context),
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
                  if (file.isDeleted && widget.onForgetLocal != null)
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _confirmForget(context),
                      icon: const Icon(Icons.visibility_off_outlined),
                      label: const Text('Forget on phone'),
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
                  if (file.isDeleted &&
                      !file.hasLocalBytes &&
                      widget.onForgetLocal == null)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Removed from PC — metadata only'),
                    )
                  else if (file.isDeleted && !file.hasLocalBytes)
                    const SizedBox.shrink()
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
