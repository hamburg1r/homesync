import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        decoration: const InputDecoration(
          labelText: 'Group name',
          hintText: 'misc',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
