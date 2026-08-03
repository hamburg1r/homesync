import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';

/// Group name + optional tags / source_kind before picking a folder or file.
class FolderNameDialog extends StatefulWidget {
  const FolderNameDialog({
    super.key,
    this.title = 'Folder rule name',
    this.confirmLabel = 'Pick folder',
  });

  final String title;
  final String confirmLabel;

  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  final _name = TextEditingController();
  final _tags = TextEditingController();
  final _sourceKind = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _tags.dispose();
    _sourceKind.dispose();
    super.dispose();
  }

  List<String> _parseTags() {
    return _tags.text
        .split(RegExp(r'[,;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void _submit() {
    Navigator.pop(
      context,
      TrackingRuleDraft(
        name: _name.text,
        patternOrUri: '',
        tags: _parseTags(),
        sourceKind:
            _sourceKind.text.trim().isEmpty ? null : _sourceKind.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'misc',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags (optional)',
                hintText: 'whatsapp, media',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sourceKind,
              decoration: const InputDecoration(
                labelText: 'Source kind override (optional)',
                hintText: 'whatsapp | camera | download | misc',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
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
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
