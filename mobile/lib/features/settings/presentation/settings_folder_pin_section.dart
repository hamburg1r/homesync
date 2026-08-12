import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';

class SettingsFolderPinSection extends StatelessWidget {
  const SettingsFolderPinSection({
    super.key,
    required this.subscriptions,
    required this.loading,
    this.onToggle,
    this.onDelete,
    this.onAdd,
  });

  final List<FolderPinSubscription> subscriptions;
  final bool loading;
  final Future<void> Function(FolderPinSubscription sub, bool enabled)?
      onToggle;
  final Future<void> Function(FolderPinSubscription sub)? onDelete;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Keep folders on device',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Auto-download catalog files under a path prefix (e.g. vault/) '
          'into a phone folder, and remove them when the PC does. '
          'Not the same as phone→PC tracking rules.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (subscriptions.isEmpty)
          const ListTile(
            dense: true,
            title: Text('No folder subscriptions'),
            subtitle: Text(
              'Use Folders browse → Keep this folder on device, or Add below.',
            ),
          )
        else
          ...subscriptions.map(
            (sub) => SwitchListTile(
              dense: true,
              title: Text(sub.name),
              subtitle: Text(
                '${sub.pathPrefix}\n→ ${sub.localRoot}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: true,
              value: sub.enabled,
              onChanged: onToggle == null
                  ? null
                  : (v) => onToggle!(sub, v),
              secondary: onDelete == null
                  ? null
                  : IconButton(
                      tooltip: 'Remove subscription',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => onDelete!(sub),
                    ),
            ),
          ),
        if (onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder subscription'),
            ),
          ),
      ],
    );
  }
}
