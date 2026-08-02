import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
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
    this.currentDeviceId,
    this.onListDevices,
    this.onReclaimDevice,
    this.onResetDevice,
  });

  final SettingsStore settings;
  final TrackingRepository tracking;
  final VoidCallback? onRulesChanged;
  final String? currentDeviceId;
  final Future<List<DeviceInfo>> Function()? onListDevices;
  final Future<String?> Function(String deviceId)? onReclaimDevice;
  final Future<String?> Function()? onResetDevice;

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

  Future<void> _addFileRule() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _FolderNameDialog(
        title: 'File rule name',
        confirmLabel: 'Pick file',
      ),
    );
    if (name == null || !mounted) return;

    final result = await FilePicker.pickFiles(allowMultiple: false);
    final path = result?.files.isNotEmpty == true ? result!.files.first.path : null;
    if (path == null || path.isEmpty) return;
    await widget.tracking.addRule(
      name: name,
      kind: TrackingRuleKind.file,
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

  Future<void> _reclaimDevice() async {
    final listFn = widget.onListDevices;
    final reclaimFn = widget.onReclaimDevice;
    if (listFn == null || reclaimFn == null) return;

    List<DeviceInfo> devices;
    try {
      devices = await listFn();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not list devices: $e')),
      );
      return;
    }
    if (!mounted) return;

    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _ReclaimDeviceDialog(
        devices: devices,
        currentDeviceId: widget.currentDeviceId,
      ),
    );
    if (chosen == null || !mounted) return;

    final err = await reclaimFn(chosen);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Reclaimed device $chosen')),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _resetDevice() async {
    final resetFn = widget.onResetDevice;
    if (resetFn == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset device identity?'),
        content: const Text(
          'This phone will get a new device ID. Previous availability '
          'rows on the PC stay under the old ID. Prefer Reclaim if you '
          'reinstalled and still have the old ID on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await resetFn();
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('New device identity registered')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
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
            if (widget.onListDevices != null &&
                widget.onReclaimDevice != null) ...[
              const SizedBox(height: 16),
              Text('Device ID', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Survives app restarts but not reinstalls. Reclaim a known '
                'server device after wipe, or reset to a new identity.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SelectableText(
                widget.currentDeviceId ?? '(not registered yet)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _reclaimDevice,
                    icon: const Icon(Icons.devices_other),
                    label: const Text('Reclaim device'),
                  ),
                  if (widget.onResetDevice != null)
                    OutlinedButton.icon(
                      onPressed: _resetDevice,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset identity'),
                    ),
                  if (widget.currentDeviceId != null)
                    IconButton(
                      tooltip: 'Copy device ID',
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(
                          ClipboardData(text: widget.currentDeviceId!),
                        );
                        if (!mounted) return;
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Device ID copied')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save & sync')),
            const Divider(height: 32),
            Text('Sync', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sync with PC'),
              subtitle: const Text(
                'Catalog delta + tracking uploads. Off = browse local only.',
              ),
              value: widget.settings.syncEnabled,
              onChanged: (value) async {
                await widget.settings.setSyncEnabled(value);
                setState(() {});
              },
            ),
            const Divider(height: 32),
            Text('Downloads', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Default folder for Pin / Bring to phone. Empty uses the app '
              'hash pin store. You can still pick a path per download.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pin download folder'),
              subtitle: Text(
                widget.settings.pinDestinationDir ??
                    'App default (homesync_pins)',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.settings.pinDestinationDir != null)
                    IconButton(
                      tooltip: 'Clear',
                      onPressed: () async {
                        await widget.settings.setPinDestinationDir(null);
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear),
                    ),
                  IconButton(
                    tooltip: 'Pick folder',
                    onPressed: () async {
                      final path = await FilePicker.getDirectoryPath();
                      if (path == null) return;
                      await widget.settings.setPinDestinationDir(path);
                      setState(() {});
                    },
                    icon: const Icon(Icons.folder_open),
                  ),
                ],
              ),
            ),
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
              '(e.g. *.pdf). Folder rules ingest every file in that tree. '
              'File rules upload one chosen path.',
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
              runSpacing: 8,
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
                OutlinedButton.icon(
                  onPressed: _addFileRule,
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: const Text('Add file'),
                ),
              ],
            ),
          ],
        ),
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
  const _FolderNameDialog({
    this.title = 'Folder rule name',
    this.confirmLabel = 'Pick folder',
  });

  final String title;
  final String confirmLabel;

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

class _ReclaimDeviceDialog extends StatefulWidget {
  const _ReclaimDeviceDialog({
    required this.devices,
    this.currentDeviceId,
  });

  final List<DeviceInfo> devices;
  final String? currentDeviceId;

  @override
  State<_ReclaimDeviceDialog> createState() => _ReclaimDeviceDialogState();
}

class _ReclaimDeviceDialogState extends State<_ReclaimDeviceDialog> {
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
