import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

class AddTrackingRuleDialog extends StatefulWidget {
  const AddTrackingRuleDialog({super.key, required this.kind});

  final TrackingRuleKind kind;

  @override
  State<AddTrackingRuleDialog> createState() => _AddTrackingRuleDialogState();
}

class _AddTrackingRuleDialogState extends State<AddTrackingRuleDialog> {
  final _name = TextEditingController();
  final _pattern = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.kind == TrackingRuleKind.regex
            ? 'Add regex rule'
            : 'Add folder rule',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'misc',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pattern,
            decoration: const InputDecoration(
              labelText: 'Pattern',
              hintText: '*.pdf',
              border: OutlineInputBorder(),
            ),
          ),
        ],
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
              TrackingRuleDraft(name: _name.text, patternOrUri: _pattern.text),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
