import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _url;
  late final TextEditingController _name;
  String? _urlError;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.settings.baseUrl);
    _name = TextEditingController(text: widget.settings.deviceName);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final err = SettingsStore.validateBaseUrl(_url.text);
    if (err != null) {
      setState(() => _urlError = err);
      return;
    }
    setState(() => _urlError = null);
    await widget.settings.setBaseUrl(_url.text);
    await widget.settings.setDeviceName(_name.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
            controller: _url,
            decoration: InputDecoration(
              labelText: 'API base URL',
              hintText: SettingsStore.defaultBaseUrl,
              border: const OutlineInputBorder(),
              errorText: _urlError,
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) {
              if (_urlError != null) {
                setState(() => _urlError = null);
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Device name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save & sync')),
        ],
      ),
    );
  }
}
