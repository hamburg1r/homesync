import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';

/// Lists active KeePass conflicts; tap opens interactive merge detail.
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
  KdbxConflict? _detail;

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
        if (_detail != null) {
          final id = _detail!.conflictId;
          _detail = list.cast<KdbxConflict?>().firstWhere(
                (c) => c?.conflictId == id,
                orElse: () => null,
              );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _resolveWithFile(KdbxConflict conflict) async {
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
    setState(() => _detail = null);
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
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Secret saved on PC')),
    );
  }

  Future<void> _recheck(KdbxConflict conflict) async {
    setState(() => _busyId = conflict.conflictId);
    final result = await widget.cubit.recheckKdbxConflict(conflict.conflictId);
    if (!mounted) return;
    setState(() => _busyId = null);
    if (result is String) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
      return;
    }
    if (result is CatalogFile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conflict auto-resolved')),
      );
      setState(() => _detail = null);
      await _reload();
      return;
    }
    if (result is KdbxConflict) {
      setState(() => _detail = result);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rechecked: ${result.state}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.98,
      builder: (context, scrollController) {
        if (_detail != null) {
          return _KdbxConflictDetail(
            conflict: _detail!,
            cubit: widget.cubit,
            busy: _busyId == _detail!.conflictId,
            scrollController: scrollController,
            onBack: () => setState(() => _detail = null),
            onResolved: () async {
              setState(() => _detail = null);
              await _reload();
            },
            onResolveWithFile: () => unawaited(_resolveWithFile(_detail!)),
            onSetSecret: () => unawaited(_setSecret(_detail!)),
            onRecheck: () => unawaited(_recheck(_detail!)),
            onBusy: (busy) => setState(
              () => _busyId = busy ? _detail!.conflictId : null,
            ),
          );
        }
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
                  'Tap a conflict to keep PC/phone vault or decide per entry. '
                  'Passwords are never shown.',
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!))
                        : (_conflicts == null || _conflicts!.isEmpty)
                            ? const Center(
                                child: Text(
                                  'No active conflicts '
                                  '(open / needs password / diff failed)',
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: _conflicts!.length,
                                itemBuilder: (context, i) {
                                  final c = _conflicts![i];
                                  final busy = _busyId == c.conflictId;
                                  final needsSecret =
                                      c.state == 'needs_secret' ||
                                          (c.diffSummary?['classification'] ==
                                              'needs_secret');
                                  return ListTile(
                                    title: Text(c.fileId),
                                    subtitle: Text(
                                      '${c.state} · ${c.redactedDiffLabel}\n'
                                      '${c.candidates.length} candidates',
                                    ),
                                    isThreeLine: true,
                                    onTap: busy
                                        ? null
                                        : () => setState(() => _detail = c),
                                    trailing: busy
                                        ? const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : needsSecret
                                            ? FilledButton(
                                                onPressed: () =>
                                                    unawaited(_setSecret(c)),
                                                child: const Text('Password'),
                                              )
                                            : const Icon(Icons.chevron_right),
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

class _KdbxConflictDetail extends StatefulWidget {
  const _KdbxConflictDetail({
    required this.conflict,
    required this.cubit,
    required this.busy,
    required this.scrollController,
    required this.onBack,
    required this.onResolved,
    required this.onResolveWithFile,
    required this.onSetSecret,
    required this.onRecheck,
    required this.onBusy,
  });

  final KdbxConflict conflict;
  final CatalogCubit cubit;
  final bool busy;
  final ScrollController scrollController;
  final VoidCallback onBack;
  final Future<void> Function() onResolved;
  final VoidCallback onResolveWithFile;
  final VoidCallback onSetSecret;
  final VoidCallback onRecheck;
  final void Function(bool busy) onBusy;

  @override
  State<_KdbxConflictDetail> createState() => _KdbxConflictDetailState();
}

class _KdbxConflictDetailState extends State<_KdbxConflictDetail> {
  late Map<String, String> _choices;

  @override
  void initState() {
    super.initState();
    _choices = _defaultsFor(widget.conflict);
  }

  @override
  void didUpdateWidget(covariant _KdbxConflictDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conflict.conflictId != widget.conflict.conflictId ||
        oldWidget.conflict.updatedAt != widget.conflict.updatedAt) {
      _choices = _defaultsFor(widget.conflict);
    }
  }

  Map<String, String> _defaultsFor(KdbxConflict c) {
    final map = <String, String>{};
    for (final e in c.contestedEntries()) {
      map[e.entryUuid] = switch (e.kind) {
        'removed' => 'base',
        'added' => 'incoming',
        'modified' => 'incoming',
        _ => 'base',
      };
    }
    return map;
  }

  Future<void> _applyCandidate(KdbxConflictCandidate cand, String label) async {
    widget.onBusy(true);
    final err = await widget.cubit.resolveKdbxConflictRequest(
      conflictId: widget.conflict.conflictId,
      fileId: widget.conflict.fileId,
      request: KdbxResolveRequest.candidate(
        contentHash: cand.contentHash,
        sizeBytes: cand.sizeBytes,
        note: 'keep $label vault',
      ),
    );
    if (!mounted) return;
    widget.onBusy(false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Kept $label vault')),
    );
    await widget.onResolved();
  }

  Future<void> _applyEntries() async {
    final base = widget.conflict.candidateByRole('base');
    final incoming = widget.conflict.candidateByRole('incoming');
    if (base == null || incoming == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Need base + incoming candidates for entry merge'),
        ),
      );
      return;
    }
    if (widget.conflict.hasExtraCandidates) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Extra candidates present — Keep PC or Keep phone first',
          ),
        ),
      );
      return;
    }
    widget.onBusy(true);
    final err = await widget.cubit.resolveKdbxConflictRequest(
      conflictId: widget.conflict.conflictId,
      fileId: widget.conflict.fileId,
      request: KdbxResolveRequest.entries(
        baseHash: base.contentHash,
        incomingHash: incoming.contentHash,
        choices: [
          for (final e in _choices.entries)
            KdbxEntryChoice(entryUuid: e.key, keep: e.value),
        ],
        note: 'resolved on phone',
      ),
    );
    if (!mounted) return;
    widget.onBusy(false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Merge applied')),
    );
    await widget.onResolved();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conflict;
    final needsSecret = c.state == 'needs_secret' ||
        (c.diffSummary?['classification'] == 'needs_secret');
    final base = c.candidateByRole('base');
    final incoming = c.candidateByRole('incoming');
    final contested = c.contestedEntries();
    final entryMergeBlocked = needsSecret || c.hasExtraCandidates;
    final entryMergeBlockReason = needsSecret
        ? 'Set the vault password and Recheck before applying an entry merge.'
        : 'Extra phone candidates present — Keep PC or Keep phone first '
            '(entry merge needs a single base + incoming pair).';
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    'Merge vault',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (widget.busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '${c.state} · ${c.redactedDiffLabel}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                Text('Vault password (PC)', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  needsSecret
                      ? 'Required on the PC daemon before diffs or entry merge. '
                          'The password is never shown here.'
                      : 'Stored only on the Linux daemon. Never shown in the app — '
                          'use this to replace it, then Recheck.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: widget.busy ? null : widget.onSetSecret,
                      child: Text(
                        needsSecret ? 'Set password' : 'Change password',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: widget.busy ? null : widget.onRecheck,
                      child: const Text('Recheck'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('Whole vault', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  c.hasExtraCandidates
                      ? 'Multiple phone candidates — Keep PC / Keep phone '
                          'first, then re-open if you need entry merge on a '
                          'simpler conflict.'
                      : 'Replace head with one candidate (skips entry merge).',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (base != null)
                      OutlinedButton(
                        onPressed: widget.busy
                            ? null
                            : () => unawaited(_applyCandidate(base, 'PC')),
                        child: const Text('Keep PC'),
                      ),
                    if (incoming != null)
                      OutlinedButton(
                        onPressed: widget.busy
                            ? null
                            : () =>
                                unawaited(_applyCandidate(incoming, 'phone')),
                        child: const Text('Keep phone'),
                      ),
                    TextButton(
                      onPressed:
                          widget.busy ? null : widget.onResolveWithFile,
                      child: const Text('Resolve with file…'),
                    ),
                  ],
                ),
                if (contested.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Contested entries', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    entryMergeBlocked
                        ? entryMergeBlockReason
                        : 'Field names only — never secrets. Apply rebuilds '
                            'the vault on the PC.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: entryMergeBlocked
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final e in contested) ...[
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.identity ?? e.entryUuid,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              switch (e.kind) {
                                'removed' => 'Removed on phone',
                                'added' => 'Added on phone',
                                'modified' => e.fields.isEmpty
                                    ? 'Modified'
                                    : 'Modified: ${e.fields.join(', ')}',
                                _ => e.kind,
                              },
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: switch (e.kind) {
                                'removed' => const [
                                    ButtonSegment(
                                      value: 'base',
                                      label: Text('Keep on PC'),
                                    ),
                                    ButtonSegment(
                                      value: 'incoming',
                                      label: Text('Accept deletion'),
                                    ),
                                  ],
                                'added' => const [
                                    ButtonSegment(
                                      value: 'incoming',
                                      label: Text('Keep'),
                                    ),
                                    ButtonSegment(
                                      value: 'discard',
                                      label: Text('Discard'),
                                    ),
                                  ],
                                _ => const [
                                    ButtonSegment(
                                      value: 'base',
                                      label: Text('PC'),
                                    ),
                                    ButtonSegment(
                                      value: 'incoming',
                                      label: Text('Phone'),
                                    ),
                                  ],
                              },
                              selected: {
                                _choices[e.entryUuid] ??
                                    (e.kind == 'added' ? 'incoming' : 'base'),
                              },
                              onSelectionChanged:
                                  (widget.busy || entryMergeBlocked)
                                      ? null
                                      : (v) {
                                          setState(() {
                                            _choices[e.entryUuid] = v.first;
                                          });
                                        },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: (widget.busy || entryMergeBlocked)
                        ? null
                        : () => unawaited(_applyEntries()),
                    child: const Text('Apply merge'),
                  ),
                ] else if (!needsSecret) ...[
                  const SizedBox(height: 20),
                  Text('Contested entries', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'No contested entries in the stored diff. Use Recheck '
                    'after setting the password, or resolve with a whole vault.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
