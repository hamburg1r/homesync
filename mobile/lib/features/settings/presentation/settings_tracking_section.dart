import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

class SettingsTrackingSection extends StatelessWidget {
  const SettingsTrackingSection({
    super.key,
    required this.rules,
    required this.loading,
    required this.onToggleRule,
    required this.onDeleteRule,
    required this.onAddRegex,
    required this.onAddFolder,
    required this.onAddFile,
    required this.onAddChildRegex,
  });

  final List<TrackingRule> rules;
  final bool loading;
  final Future<void> Function(TrackingRule rule, bool enabled) onToggleRule;
  final Future<void> Function(TrackingRule rule) onDeleteRule;
  final VoidCallback onAddRegex;
  final VoidCallback onAddFolder;
  final VoidCallback onAddFile;
  final Future<void> Function(TrackingRule folder) onAddChildRegex;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tracking rules', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Empty = no automatic upload. Regex matches filenames '
          '(e.g. *.pdf). Folder rules ingest every file in that tree; '
          'optional include-regex children filter within the folder. '
          'File rules upload one chosen path. Tags apply on ingest.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (rules.isEmpty)
          Text(
            'No tracking rules — nothing is uploaded automatically.',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        else
          ...rules.map((rule) => _RuleTile(
                rule: rule,
                onToggleRule: onToggleRule,
                onDeleteRule: onDeleteRule,
                onAddChildRegex: onAddChildRegex,
              )),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: onAddRegex,
              icon: const Icon(Icons.pattern),
              label: const Text('Add regex'),
            ),
            OutlinedButton.icon(
              onPressed: onAddFolder,
              icon: const Icon(Icons.folder_outlined),
              label: const Text('Add folder'),
            ),
            OutlinedButton.icon(
              onPressed: onAddFile,
              icon: const Icon(Icons.insert_drive_file_outlined),
              label: const Text('Add file'),
            ),
          ],
        ),
      ],
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.onToggleRule,
    required this.onDeleteRule,
    required this.onAddChildRegex,
    this.indent = 0,
  });

  final TrackingRule rule;
  final Future<void> Function(TrackingRule rule, bool enabled) onToggleRule;
  final Future<void> Function(TrackingRule rule) onDeleteRule;
  final Future<void> Function(TrackingRule folder) onAddChildRegex;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFolder = rule.kind == TrackingRuleKind.folder;
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(rule.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rule.kind.wire}: ${rule.summary}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (rule.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final t in rule.tags)
                          Chip(
                            label: Text(t),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            labelStyle: theme.textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
                if (rule.sourceKind != null)
                  Text(
                    'source_kind: ${rule.sourceKind}',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
            isThreeLine: rule.tags.isNotEmpty || rule.sourceKind != null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: rule.enabled,
                  onChanged: (v) => onToggleRule(rule, v),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => onDeleteRule(rule),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          if (isFolder) ...[
            for (final child in rule.children)
              _RuleTile(
                rule: child,
                onToggleRule: onToggleRule,
                onDeleteRule: onDeleteRule,
                onAddChildRegex: onAddChildRegex,
                indent: 16,
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => onAddChildRegex(rule),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('Add include regex'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
