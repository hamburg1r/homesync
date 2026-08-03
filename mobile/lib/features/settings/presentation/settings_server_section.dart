import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class SettingsServerSection extends StatelessWidget {
  const SettingsServerSection({
    super.key,
    required this.urlController,
    required this.nameController,
    this.urlError,
    this.currentDeviceId,
    this.onUrlChanged,
    this.onReclaimDevice,
    this.onResetDevice,
    this.onSave,
  });

  final TextEditingController urlController;
  final TextEditingController nameController;
  final String? urlError;
  final String? currentDeviceId;
  final ValueChanged<String>? onUrlChanged;
  final VoidCallback? onReclaimDevice;
  final VoidCallback? onResetDevice;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Server', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Emulator default is 10.0.2.2 (host loopback). '
          'On a physical phone use your PC LAN/Tailscale IP.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: urlController,
          decoration: InputDecoration(
            labelText: 'API base URL',
            hintText: SettingsStore.defaultBaseUrl,
            border: const OutlineInputBorder(),
            errorText: urlError,
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: onUrlChanged,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Device name',
            border: OutlineInputBorder(),
          ),
        ),
        if (onReclaimDevice != null) ...[
          const SizedBox(height: 16),
          Text('Device ID', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Survives app restarts but not reinstalls. Reclaim a known '
            'server device after wipe, or reset to a new identity.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SelectableText(
            currentDeviceId ?? '(not registered yet)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReclaimDevice,
                icon: const Icon(Icons.devices_other),
                label: const Text('Reclaim device'),
              ),
              if (onResetDevice != null)
                OutlinedButton.icon(
                  onPressed: onResetDevice,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reset identity'),
                ),
              if (currentDeviceId != null)
                IconButton(
                  tooltip: 'Copy device ID',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                      ClipboardData(text: currentDeviceId!),
                    );
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Device ID copied')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(onPressed: onSave, child: const Text('Save & sync')),
      ],
    );
  }
}
