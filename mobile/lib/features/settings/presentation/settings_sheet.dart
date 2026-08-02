import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_pattern.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.settings,
    required this.tracking,
    this.onRulesChanged,
  });

  final SettingsStore settings;
  final TrackingRepository tracking;
  final VoidCallback? onRulesChanged;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _url;
  late final TextEditingController _name;
  String? _urlError;
  List<TrackingRule> _rules = const [];
  bool _loadingRules = true;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.settings.baseUrl);
    _name = TextEditingController(text: widget.settings.deviceName);
    _reloadRules();
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _reloadRules() async {
    final rules = await widget.tracking.listRules();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _loadingRules = false;
    });
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

  Future<void> _addRegexRule() async {
    final result = await showDialog<_RuleDraft>(
      context: context,
      builder: (context) => const _AddRuleDialog(kind: TrackingRuleKind.regex),
    );
    if (result == null) return;
    try {
      TrackingPattern.compile(result.patternOrUri);
      await widget.tracking.addRule(
        name: result.name,
        kind: TrackingRuleKind.regex,
        patternOrUri: result.patternOrUri,
      );
      widget.onRulesChanged?.call();
      await _reloadRules();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid pattern: $e')),
      );
    }
  }

  Future<void> _addFolderRule() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _FolderNameDialog(),
    );
    if (name == null || !mounted) return;

    final path = await FilePicker.getDirectoryPath();
    if (path == null) return;
    await widget.tracking.addRule(
      name: name,
      kind: TrackingRuleKind.folder,
      patternOrUri: path,
    );
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  Future<void> _deleteRule(TrackingRule rule) async {
    await widget.tracking.deleteRule(rule.id);
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  Future<void> _toggleRule(TrackingRule rule, bool enabled) async {
    await widget.tracking.setRuleEnabled(rule.id, enabled);
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottom),
      child: SingleChildScrollView(
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
            const Divider(height: 32),
            Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Theme follows the system by default. Dynamic color uses '
              'wallpaper colors on Android 12+ (Material You).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {widget.settings.themeMode},
              onSelectionChanged: (selected) async {
                await widget.settings.setThemeMode(selected.first);
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dynamic color'),
              subtitle: const Text('Material You from wallpaper'),
              value: widget.settings.useDynamicColor,
              onChanged: (value) async {
                await widget.settings.setUseDynamicColor(value);
                setState(() {});
              },
            ),
            const Divider(height: 32),
            Text('Tracking rules', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Empty = no automatic upload. Regex matches filenames '
              '(e.g. *.pdf). Folder rules ingest every file in that tree.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_loadingRules)
              const Center(child: CircularProgressIndicator())
            else if (_rules.isEmpty)
              Text(
                'No tracking rules — nothing is uploaded automatically.',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              ..._rules.map(
                (rule) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(rule.name),
                  subtitle: Text(
                    '${rule.kind.wire}: ${rule.summary}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: rule.enabled,
                        onChanged: (v) => _toggleRule(rule, v),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _deleteRule(rule),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addRegexRule,
                  icon: const Icon(Icons.pattern),
                  label: const Text('Add regex'),
                ),
                OutlinedButton.icon(
                  onPressed: _addFolderRule,
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('Add folder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleDraft {
  const _RuleDraft({required this.name, required this.patternOrUri});

  final String name;
  final String patternOrUri;
}

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog();

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Folder rule name'),
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
          child: const Text('Pick folder'),
        ),
      ],
    );
  }
}

class _AddRuleDialog extends StatefulWidget {
  const _AddRuleDialog({required this.kind});

  final TrackingRuleKind kind;

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
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
              _RuleDraft(name: _name.text, patternOrUri: _pattern.text),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
