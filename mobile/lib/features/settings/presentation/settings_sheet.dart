import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/settings/presentation/add_tracking_rule_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/folder_name_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/reclaim_device_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_appearance_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_downloads_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_server_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_sync_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_tracking_section.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';
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
    final result = await showDialog<TrackingRuleDraft>(
      context: context,
      builder: (context) =>
          const AddTrackingRuleDialog(kind: TrackingRuleKind.regex),
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
      builder: (context) => const FolderNameDialog(),
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
      builder: (context) => const FolderNameDialog(
        title: 'File rule name',
        confirmLabel: 'Pick file',
      ),
    );
    if (name == null || !mounted) return;

    final result = await FilePicker.pickFiles(allowMultiple: false);
    final path =
        result?.files.isNotEmpty == true ? result!.files.first.path : null;
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
      builder: (context) => ReclaimDeviceDialog(
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
              SettingsServerSection(
                urlController: _url,
                nameController: _name,
                urlError: _urlError,
                currentDeviceId: widget.currentDeviceId,
                onUrlChanged: (_) {
                  if (_urlError != null) {
                    setState(() => _urlError = null);
                  }
                },
                onReclaimDevice: widget.onListDevices != null &&
                        widget.onReclaimDevice != null
                    ? _reclaimDevice
                    : null,
                onResetDevice:
                    widget.onResetDevice != null ? _resetDevice : null,
                onSave: _save,
              ),
              const Divider(height: 32),
              ListenableBuilder(
                listenable: widget.settings,
                builder: (context, _) => SettingsSyncSection(
                  settings: widget.settings,
                ),
              ),
              const Divider(height: 32),
              SettingsDownloadsSection(
                settings: widget.settings,
                onChanged: () => setState(() {}),
              ),
              const Divider(height: 32),
              SettingsAppearanceSection(
                settings: widget.settings,
                onChanged: () => setState(() {}),
              ),
              const Divider(height: 32),
              SettingsTrackingSection(
                rules: _rules,
                loading: _loadingRules,
                onToggleRule: _toggleRule,
                onDeleteRule: _deleteRule,
                onAddRegex: _addRegexRule,
                onAddFolder: _addFolderRule,
                onAddFile: _addFileRule,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
