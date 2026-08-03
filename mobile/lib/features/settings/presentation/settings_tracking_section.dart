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
  });

  final List<TrackingRule> rules;
  final bool loading;
  final Future<void> Function(TrackingRule rule, bool enabled) onToggleRule;
  final Future<void> Function(TrackingRule rule) onDeleteRule;
  final VoidCallback onAddRegex;
  final VoidCallback onAddFolder;
  final VoidCallback onAddFile;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tracking rules', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Empty = no automatic upload. Regex matches filenames '
          '(e.g. *.pdf). Folder rules ingest every file in that tree. '
          'File rules upload one chosen path.',
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
          ...rules.map(
            (rule) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(rule.name),
              subtitle: Text(
                '${rule.kind.wire}: ${rule.summary}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
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
          ),
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
