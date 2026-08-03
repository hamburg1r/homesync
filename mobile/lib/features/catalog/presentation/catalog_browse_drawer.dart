import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

class CatalogBrowseDrawer extends StatelessWidget {
  const CatalogBrowseDrawer({
    super.key,
    required this.browseMode,
    this.groupRuleId,
    this.deviceAndSyncedOnly = false,
    this.rules = const [],
    this.onSelectBrowse,
    this.onToggleDeviceSynced,
    this.onOpenSettings,
  });

  final BrowseMode browseMode;
  final String? groupRuleId;
  final bool deviceAndSyncedOnly;
  final List<TrackingRule> rules;
  final void Function(
    BrowseMode mode, {
    String? ruleId,
    String? title,
  })? onSelectBrowse;
  final ValueChanged<bool>? onToggleDeviceSynced;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  'Browse',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('On this device & synced'),
              subtitle: const Text('Hide listed-only / pending'),
              value: deviceAndSyncedOnly,
              onChanged: onToggleDeviceSynced,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('All (catalog)'),
              selected: browseMode == BrowseMode.allCatalog,
              onTap: () {
                onSelectBrowse?.call(BrowseMode.allCatalog);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Tracked on device'),
              selected: browseMode == BrowseMode.trackedOnDevice,
              onTap: () {
                onSelectBrowse?.call(BrowseMode.trackedOnDevice);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Untracked'),
              selected: browseMode == BrowseMode.untrackedOnDevice,
              onTap: () {
                onSelectBrowse?.call(BrowseMode.untrackedOnDevice);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Removed from PC'),
              subtitle: const Text('Soft-deleted; may still be on device'),
              selected: browseMode == BrowseMode.removedFromPc,
              onTap: () {
                onSelectBrowse?.call(BrowseMode.removedFromPc);
                Navigator.pop(context);
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Groups',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (rules.isEmpty)
              const ListTile(
                dense: true,
                title: Text('No tracking rules yet'),
                subtitle: Text('Add regex or folder rules in Settings'),
              )
            else
              ...rules.map(
                (rule) => ListTile(
                  leading: Icon(
                    rule.kind == TrackingRuleKind.folder
                        ? Icons.folder_outlined
                        : Icons.pattern,
                  ),
                  title: Text(rule.name),
                  subtitle: Text(
                    rule.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: browseMode == BrowseMode.group &&
                      groupRuleId == rule.id,
                  onTap: () {
                    onSelectBrowse?.call(
                      BrowseMode.group,
                      ruleId: rule.id,
                      title: rule.name,
                    );
                    Navigator.pop(context);
                  },
                ),
              ),
            const Divider(),
            if (onOpenSettings != null)
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () {
                  Navigator.pop(context);
                  onOpenSettings!();
                },
              ),
          ],
        ),
      ),
    );
  }
}
