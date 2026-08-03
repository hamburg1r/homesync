import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class SettingsDownloadsSection extends StatelessWidget {
  const SettingsDownloadsSection({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Downloads', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Default folder for Pin / Bring to phone. Empty uses the app '
          'hash pin store. You can still pick a path per download.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Pin download folder'),
          subtitle: Text(
            settings.pinDestinationDir ?? 'App default (homesync_pins)',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (settings.pinDestinationDir != null)
                IconButton(
                  tooltip: 'Clear',
                  onPressed: () async {
                    await settings.setPinDestinationDir(null);
                    onChanged();
                  },
                  icon: const Icon(Icons.clear),
                ),
              IconButton(
                tooltip: 'Pick folder',
                onPressed: () async {
                  final path = await FilePicker.getDirectoryPath();
                  if (path == null) return;
                  await settings.setPinDestinationDir(path);
                  onChanged();
                },
                icon: const Icon(Icons.folder_open),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
