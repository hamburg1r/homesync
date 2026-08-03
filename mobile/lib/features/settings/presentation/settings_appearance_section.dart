import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class SettingsAppearanceSection extends StatelessWidget {
  const SettingsAppearanceSection({
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
        Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Theme follows the system by default. Dynamic color uses '
          'wallpaper colors on Android 12+ (Material You).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: {settings.themeMode},
          onSelectionChanged: (selected) async {
            await settings.setThemeMode(selected.first);
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dynamic color'),
          subtitle: const Text('Material You from wallpaper'),
          value: settings.useDynamicColor,
          onChanged: (value) async {
            await settings.setUseDynamicColor(value);
            onChanged();
          },
        ),
      ],
    );
  }
}
