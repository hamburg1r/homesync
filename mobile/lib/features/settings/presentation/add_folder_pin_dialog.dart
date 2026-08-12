import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';

/// Dialog to create a path-prefix folder pin subscription.
class AddFolderPinDialog extends StatefulWidget {
  const AddFolderPinDialog({
    super.key,
    this.initialPrefix = '',
    this.initialName = '',
    this.initialLocalRoot = '',
  });

  final String initialPrefix;
  final String initialName;
  final String initialLocalRoot;

  @override
  State<AddFolderPinDialog> createState() => _AddFolderPinDialogState();
}

class _AddFolderPinDialogState extends State<AddFolderPinDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prefix;
  late final TextEditingController _localRoot;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _prefix = TextEditingController(text: widget.initialPrefix);
    _localRoot = TextEditingController(text: widget.initialLocalRoot);
  }

  @override
  void dispose() {
    _name.dispose();
    _prefix.dispose();
    _localRoot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Keep folder on device'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Obsidian vault',
              ),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _prefix,
              decoration: const InputDecoration(
                labelText: 'Catalog path prefix',
                hintText: 'vault',
                helperText: 'Matches relative_path under this directory',
              ),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _localRoot,
              decoration: const InputDecoration(
                labelText: 'Phone folder',
                hintText: '/storage/emulated/0/Documents/Vault',
                helperText: 'Files are written here preserving subpaths',
              ),
            ),
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
            final prefix = normalizeFolderPinPrefix(_prefix.text);
            final root = _localRoot.text.trim();
            if (prefix.isEmpty || root.isEmpty) return;
            Navigator.pop(
              context,
              (
                name: _name.text.trim().isEmpty ? prefix : _name.text.trim(),
                pathPrefix: prefix,
                localRoot: root,
              ),
            );
          },
          child: const Text('Keep on device'),
        ),
      ],
    );
  }
}
