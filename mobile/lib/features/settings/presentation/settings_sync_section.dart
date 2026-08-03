import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class SettingsSyncSection extends StatelessWidget {
  const SettingsSyncSection({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sync', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync with PC'),
          subtitle: const Text(
            'Catalog delta + tracking uploads. Off = browse local only.',
          ),
          value: settings.syncEnabled,
          onChanged: (value) => settings.setSyncEnabled(value),
        ),
      ],
    );
  }
}
