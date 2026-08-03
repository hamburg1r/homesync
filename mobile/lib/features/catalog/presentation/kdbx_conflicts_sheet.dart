import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';

/// Lists open KeePass conflicts and resolves by uploading a merged .kdbx.
class KdbxConflictsSheet extends StatefulWidget {
  const KdbxConflictsSheet({super.key, required this.cubit});

  final CatalogCubit cubit;

  @override
  State<KdbxConflictsSheet> createState() => _KdbxConflictsSheetState();
}

class _KdbxConflictsSheetState extends State<KdbxConflictsSheet> {
  List<KdbxConflict>? _conflicts;
  String? _error;
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.cubit.listKdbxConflicts();
      if (!mounted) return;
      setState(() {
        _conflicts = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _resolve(KdbxConflict conflict) async {
    final pick = await FilePicker.pickFiles(allowMultiple: false);
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.single.path;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read picked file path')),
        );
      }
      return;
    }
    setState(() => _busyId = conflict.conflictId);
    final err = await widget.cubit.resolveKdbxConflictWithFile(
      conflictId: conflict.conflictId,
      fileId: conflict.fileId,
      path: path,
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conflict resolved')),
    );
    await _reload();
  }

  Future<void> _setSecret(KdbxConflict conflict) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vault password for PC'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'KeePass master password',
            helperText: 'Stored only on the Linux daemon for trivial auto-diff',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save on PC'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await widget.cubit.setKdbxSecret(
      conflict.fileId,
      controller.text,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Secret saved on PC')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'KeePass conflicts',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: _loading ? null : _reload,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Merge candidates in KeePass, then pick the resolved .kdbx. '
                  'Bound to server is not required.',
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!))
                        : (_conflicts == null || _conflicts!.isEmpty)
                            ? const Center(child: Text('No open conflicts'))
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: _conflicts!.length,
                                itemBuilder: (context, i) {
                                  final c = _conflicts![i];
                                  final busy = _busyId == c.conflictId;
                                  return ListTile(
                                    title: Text(c.fileId),
                                    subtitle: Text(
                                      '${c.state} · ${c.redactedDiffLabel}\n'
                                      '${c.candidates.length} candidates',
                                    ),
                                    isThreeLine: true,
                                    trailing: busy
                                        ? const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : PopupMenuButton<String>(
                                            onSelected: (v) {
                                              if (v == 'resolve') {
                                                unawaited(_resolve(c));
                                              } else if (v == 'secret') {
                                                unawaited(_setSecret(c));
                                              }
                                            },
                                            itemBuilder: (context) => const [
                                              PopupMenuItem(
                                                value: 'resolve',
                                                child: Text('Resolve with file…'),
                                              ),
                                              PopupMenuItem(
                                                value: 'secret',
                                                child: Text(
                                                  'Set PC vault password…',
                                                ),
                                              ),
                                            ],
                                          ),
                                  );
                                },
                              ),
              ),
            ],
          ),
        );
      },
    );
  }
}
