import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';

class ReclaimDeviceDialog extends StatefulWidget {
  const ReclaimDeviceDialog({
    super.key,
    required this.devices,
    this.currentDeviceId,
  });

  final List<DeviceInfo> devices;
  final String? currentDeviceId;

  @override
  State<ReclaimDeviceDialog> createState() => _ReclaimDeviceDialogState();
}

class _ReclaimDeviceDialogState extends State<ReclaimDeviceDialog> {
  String? _selected;
  late final TextEditingController _manual;

  @override
  void initState() {
    super.initState();
    _manual = TextEditingController();
    final android = widget.devices.where((d) => d.kind == 'android').toList();
    final prefer = android.isNotEmpty ? android : widget.devices;
    if (prefer.isNotEmpty) {
      _selected = prefer.first.deviceId;
    }
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reclaim device'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pick a device already registered on the PC, or paste a '
                'device ID (e.g. after reinstall).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (widget.devices.isEmpty)
                const Text('No devices on the server yet.')
              else
                ...widget.devices.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    selected: _selected == d.deviceId,
                    title: Text('${d.name} (${d.kind})'),
                    subtitle: Text(
                      d.deviceId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _selected == d.deviceId
                        ? const Icon(Icons.check_circle)
                        : const Icon(Icons.radio_button_unchecked),
                    onTap: () => setState(() {
                      _selected = d.deviceId;
                      _manual.clear();
                    }),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _manual,
                decoration: const InputDecoration(
                  labelText: 'Or paste device ID',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  if (v.trim().isNotEmpty) {
                    setState(() => _selected = null);
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final manual = _manual.text.trim();
            final id = manual.isNotEmpty ? manual : _selected;
            if (id == null || id.isEmpty) return;
            if (id == widget.currentDeviceId) {
              Navigator.pop(context);
              return;
            }
            Navigator.pop(context, id);
          },
          child: const Text('Reclaim'),
        ),
      ],
    );
  }
}
