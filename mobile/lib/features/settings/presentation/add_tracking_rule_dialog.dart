import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

class AddTrackingRuleDialog extends StatefulWidget {
  const AddTrackingRuleDialog({
    super.key,
    required this.kind,
    this.title,
    this.showNameField = true,
    this.initialName,
    this.requirePattern = true,
  });

  final TrackingRuleKind kind;
  final String? title;
  final bool showNameField;
  final String? initialName;
  final bool requirePattern;

  @override
  State<AddTrackingRuleDialog> createState() => _AddTrackingRuleDialogState();
}

class _AddTrackingRuleDialogState extends State<AddTrackingRuleDialog> {
  late final TextEditingController _name;
  final _pattern = TextEditingController();
  final _tags = TextEditingController();
  final _sourceKind = TextEditingController();
  bool _bindToServer = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
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

  String get _dialogTitle {
    if (widget.title != null) return widget.title!;
    switch (widget.kind) {
      case TrackingRuleKind.regex:
        return 'Add regex rule';
      case TrackingRuleKind.folder:
        return 'Add folder rule';
      case TrackingRuleKind.file:
        return 'Add file rule';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegex = widget.kind == TrackingRuleKind.regex;
    return AlertDialog(
      title: Text(_dialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showNameField) ...[
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  hintText: 'misc',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.requirePattern) ...[
              TextField(
                controller: _pattern,
                decoration: InputDecoration(
                  labelText: widget.kind == TrackingRuleKind.regex
                      ? 'Pattern'
                      : 'Path / pattern',
                  hintText: '*.pdf',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
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
            ),
            if (isRegex) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bound to server'),
                subtitle: const Text(
                  'Matching files delete local pins when soft-deleted on the PC',
                ),
                value: _bindToServer,
                onChanged: (v) => setState(() => _bindToServer = v),
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
            Navigator.pop(
              context,
              TrackingRuleDraft(
                name: _name.text,
                patternOrUri: _pattern.text,
                tags: _parseTags(),
                sourceKind: _sourceKind.text.trim().isEmpty
                    ? null
                    : _sourceKind.text.trim(),
                bindToServer: isRegex && _bindToServer,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
