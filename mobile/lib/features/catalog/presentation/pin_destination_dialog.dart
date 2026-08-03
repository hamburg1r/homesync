import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';

class PinDestChoice {
  const PinDestChoice({this.directory, this.fileName});

  final String? directory;
  final String? fileName;
}

class PinDestinationDialog extends StatefulWidget {
  const PinDestinationDialog({
    super.key,
    required this.file,
    this.initialDir,
  });

  final CatalogFile file;
  final String? initialDir;

  @override
  State<PinDestinationDialog> createState() => _PinDestinationDialogState();
}

class _PinDestinationDialogState extends State<PinDestinationDialog> {
  late final TextEditingController _name;
  late String? _dir;
  bool _useAppDefault = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.file.displayName);
    _dir = widget.initialDir;
    _useAppDefault = _dir == null || _dir!.isEmpty;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null || !mounted) return;
    setState(() {
      _dir = path;
      _useAppDefault = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.file.isGhost ? 'Bring to phone' : 'Pin to this device',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'File name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('App pin store'),
              subtitle: const Text(
                'Hash-addressed under app storage. Off = choose a folder.',
              ),
              value: _useAppDefault,
              onChanged: (v) => setState(() {
                _useAppDefault = v;
                if (v) _dir = null;
              }),
            ),
            if (!_useAppDefault) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Download folder'),
                subtitle: Text(
                  (_dir == null || _dir!.isEmpty)
                      ? 'Tap to pick a folder'
                      : _dir!,
                ),
                trailing: const Icon(Icons.folder_open),
                onTap: _pickDir,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_useAppDefault && (_dir == null || _dir!.isEmpty)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Pick a download folder')),
              );
              return;
            }
            Navigator.pop(
              context,
              PinDestChoice(
                directory: _useAppDefault ? null : _dir,
                fileName: _name.text.trim().isEmpty ? null : _name.text.trim(),
              ),
            );
          },
          child: const Text('Download'),
        ),
      ],
    );
  }
}
