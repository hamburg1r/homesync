import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

/// Edit group name / tags / source_kind (and pattern for regex rules).
class EditTrackingRuleDialog extends StatefulWidget {
  const EditTrackingRuleDialog({super.key, required this.rule});

  final TrackingRule rule;

  @override
  State<EditTrackingRuleDialog> createState() => _EditTrackingRuleDialogState();
}

class _EditTrackingRuleDialogState extends State<EditTrackingRuleDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late final TextEditingController _tags;
  late final TextEditingController _sourceKind;
  late bool _bindToServer;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.rule.name);
    _pattern = TextEditingController(text: widget.rule.patternOrUri);
    _tags = TextEditingController(text: widget.rule.tags.join(', '));
    _sourceKind = TextEditingController(text: widget.rule.sourceKind ?? '');
    _bindToServer = widget.rule.bindToServer;
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

  @override
  Widget build(BuildContext context) {
    final isRegex = widget.rule.kind == TrackingRuleKind.regex;
    final isPathRule = widget.rule.kind == TrackingRuleKind.folder ||
        widget.rule.kind == TrackingRuleKind.file;
    return AlertDialog(
      title: Text('Edit ${widget.rule.kind.wire} rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.rule.isChild)
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  border: OutlineInputBorder(),
                ),
              ),
            if (!widget.rule.isChild) const SizedBox(height: 12),
            if (isRegex)
              TextField(
                controller: _pattern,
                decoration: const InputDecoration(
                  labelText: 'Pattern',
                  border: OutlineInputBorder(),
                ),
              ),
            if (isPathRule)
              TextField(
                controller: _pattern,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Path',
                  border: OutlineInputBorder(),
                  helperText: 'Path is fixed; delete and re-add to change.',
                ),
              ),
            if (isRegex || isPathRule) const SizedBox(height: 12),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags',
                hintText: 'whatsapp, media',
                border: OutlineInputBorder(),
                helperText: 'Saved tags re-sync to matching files on the PC.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sourceKind,
              decoration: const InputDecoration(
                labelText: 'Source kind override',
                hintText: 'whatsapp | camera | download | misc',
                border: OutlineInputBorder(),
                helperText: 'Blank = path heuristic. Change re-syncs matches.',
              ),
            ),
            if (isRegex) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bound to server'),
                subtitle: const Text(
                  'Matching files delete local pins when soft-deleted on the PC. '
                  'Saving re-applies to already synced matches.',
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
                name: widget.rule.isChild ? widget.rule.name : _name.text,
                patternOrUri: _pattern.text,
                tags: _parseTags(),
                sourceKind: _sourceKind.text.trim().isEmpty
                    ? null
                    : _sourceKind.text.trim(),
                bindToServer: isRegex && _bindToServer,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
