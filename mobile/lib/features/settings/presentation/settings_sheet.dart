import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/settings/presentation/add_folder_pin_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/add_tracking_rule_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/edit_tracking_rule_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/folder_name_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/reclaim_device_dialog.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_appearance_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_downloads_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_folder_pin_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_server_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_sync_section.dart';
import 'package:homesync_mobile/features/settings/presentation/settings_tracking_section.dart';
import 'package:homesync_mobile/features/settings/presentation/tracking_rule_draft.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_pattern.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.settings,
    required this.tracking,
    required this.scanner,
    this.onRulesChanged,
    this.listFolderPins,
    this.onKeepFolderOnDevice,
    this.onSetFolderPinEnabled,
    this.onDeleteFolderPin,
    this.currentDeviceId,
    this.onListDevices,
    this.onReclaimDevice,
    this.onResetDevice,
  });

  final SettingsStore settings;
  final TrackingRepository tracking;
  final DeviceScanner scanner;
  final VoidCallback? onRulesChanged;
  final Future<List<FolderPinSubscription>> Function()? listFolderPins;
  final Future<String?> Function({
    required String pathPrefix,
    required String localRoot,
    String? name,
  })? onKeepFolderOnDevice;
  final Future<String?> Function(String id, {required bool enabled})?
      onSetFolderPinEnabled;
  final Future<String?> Function(String id)? onDeleteFolderPin;
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
  List<FolderPinSubscription> _folderPins = const [];
  bool _loadingFolderPins = true;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.settings.baseUrl);
    _name = TextEditingController(text: widget.settings.deviceName);
    _reloadRules();
    _reloadFolderPins();
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

  Future<void> _reloadFolderPins() async {
    final listFn = widget.listFolderPins;
    if (listFn == null) {
      if (mounted) setState(() => _loadingFolderPins = false);
      return;
    }
    final pins = await listFn();
    if (!mounted) return;
    setState(() {
      _folderPins = pins;
      _loadingFolderPins = false;
    });
  }

  Future<void> _addFolderPin() async {
    final draft = await showDialog<
        ({String name, String pathPrefix, String localRoot})>(
      context: context,
      builder: (context) => AddFolderPinDialog(
        initialLocalRoot: widget.settings.pinDestinationDir ?? '',
      ),
    );
    if (draft == null || widget.onKeepFolderOnDevice == null) return;
    var localRoot = draft.localRoot;
    if (localRoot.isEmpty) {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Phone folder for vault',
      );
      if (picked == null) return;
      localRoot = picked;
    }
    final err = await widget.onKeepFolderOnDevice!(
      pathPrefix: draft.pathPrefix,
      localRoot: localRoot,
      name: draft.name,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await _reloadFolderPins();
  }

  Future<void> _toggleFolderPin(FolderPinSubscription sub, bool enabled) async {
    final err = await widget.onSetFolderPinEnabled?.call(
      sub.id,
      enabled: enabled,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await _reloadFolderPins();
  }

  Future<void> _deleteFolderPin(FolderPinSubscription sub) async {
    final err = await widget.onDeleteFolderPin?.call(sub.id);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await _reloadFolderPins();
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
        tags: result.tags,
        sourceKind: result.sourceKind,
        bindToServer: result.bindToServer,
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
    final draft = await showDialog<TrackingRuleDraft>(
      context: context,
      builder: (context) => const FolderNameDialog(),
    );
    if (draft == null || !mounted) return;

    final path = await FilePicker.getDirectoryPath();
    if (path == null) return;
    await widget.tracking.addRule(
      name: draft.name,
      kind: TrackingRuleKind.folder,
      patternOrUri: path,
      tags: draft.tags,
      sourceKind: draft.sourceKind,
    );
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  Future<void> _addFileRule() async {
    final draft = await showDialog<TrackingRuleDraft>(
      context: context,
      builder: (context) => const FolderNameDialog(
        title: 'File rule name',
        confirmLabel: 'Pick file',
      ),
    );
    if (draft == null || !mounted) return;

    final result = await FilePicker.pickFiles(allowMultiple: false);
    final path =
        result?.files.isNotEmpty == true ? result!.files.first.path : null;
    if (path == null || path.isEmpty) return;
    await widget.tracking.addRule(
      name: draft.name,
      kind: TrackingRuleKind.file,
      patternOrUri: path,
      tags: draft.tags,
      sourceKind: draft.sourceKind,
    );
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  Future<void> _addChildRegex(TrackingRule folder) async {
    final result = await showDialog<TrackingRuleDraft>(
      context: context,
      builder: (context) => AddTrackingRuleDialog(
        kind: TrackingRuleKind.regex,
        title: 'Include regex under ${folder.name}',
        showNameField: false,
        initialName: folder.name,
      ),
    );
    if (result == null) return;
    try {
      TrackingPattern.compile(result.patternOrUri);
      await widget.tracking.addRule(
        name: folder.name,
        kind: TrackingRuleKind.regex,
        patternOrUri: result.patternOrUri,
        parentId: folder.id,
        tags: result.tags,
        sourceKind: result.sourceKind,
        bindToServer: result.bindToServer,
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

  Future<void> _editRule(TrackingRule rule) async {
    final draft = await showDialog<TrackingRuleDraft>(
      context: context,
      builder: (context) => EditTrackingRuleDialog(rule: rule),
    );
    if (draft == null) return;
    try {
      if (rule.kind == TrackingRuleKind.regex) {
        TrackingPattern.compile(draft.patternOrUri);
      }
      final updated = rule.copyWith(
        name: draft.name,
        patternOrUri: draft.patternOrUri.trim().isEmpty
            ? rule.patternOrUri
            : draft.patternOrUri.trim(),
        tags: draft.tags,
        sourceKind: draft.sourceKind,
        clearSourceKind: draft.sourceKind == null,
        bindToServer: draft.bindToServer,
      );
      await widget.tracking.updateRule(updated);
      final result = await widget.scanner.propagateRuleEdit(
        before: rule,
        after: updated,
      );
      widget.onRulesChanged?.call();
      await _reloadRules();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Updated rule'
            '${result.tagsUpdated > 0 ? '; tags synced on ${result.tagsUpdated}' : ''}'
            '${result.sourceKindUpdated > 0 ? '; source_kind synced on ${result.sourceKindUpdated}' : ''}'
            '${result.bindUpdated > 0 ? '; bound-to-server on ${result.bindUpdated}' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update rule: $e')),
      );
    }
  }

  Future<void> _deleteRule(TrackingRule rule) async {
    await widget.tracking.deleteRule(rule.id);
    widget.onRulesChanged?.call();
    await _reloadRules();
  }

  Future<void> _toggleRule(TrackingRule rule, bool enabled) async {
    final cancelled = await widget.scanner.setRuleEnabled(rule, enabled);
    widget.onRulesChanged?.call();
    await _reloadRules();
    if (!mounted || enabled || cancelled == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Disabled — cancelled $cancelled pending upload'
          '${cancelled == 1 ? '' : 's'}'
          ' (any already in flight may still finish)',
        ),
      ),
    );
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
              SettingsFolderPinSection(
                subscriptions: _folderPins,
                loading: _loadingFolderPins,
                onToggle: widget.onSetFolderPinEnabled == null
                    ? null
                    : _toggleFolderPin,
                onDelete: widget.onDeleteFolderPin == null
                    ? null
                    : _deleteFolderPin,
                onAdd: widget.onKeepFolderOnDevice == null
                    ? null
                    : _addFolderPin,
              ),
              const Divider(height: 32),
              SettingsTrackingSection(
                rules: _rules,
                loading: _loadingRules,
                onToggleRule: _toggleRule,
                onDeleteRule: _deleteRule,
                onEditRule: _editRule,
                onAddRegex: _addRegexRule,
                onAddFolder: _addFolderRule,
                onAddFile: _addFileRule,
                onAddChildRegex: _addChildRegex,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
