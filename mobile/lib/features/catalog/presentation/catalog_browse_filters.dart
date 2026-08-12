import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';

/// Human-readable summary for the drawer status filter control.
String formatStatusFilterSummary(Set<CatalogShowKind> visible) {
  if (visible.length >= CatalogShowKind.values.length) return 'All statuses';
  if (visible.isEmpty) return 'None';
  final labels = CatalogShowKind.values
      .where(visible.contains)
      .map((k) => k.label)
      .toList();
  return labels.join(', ');
}

/// Drawer status filter — chip / availability categories in the browse list.
enum CatalogShowKind {
  listed,
  cached,
  pinned,
  pending,
  failed;

  String get label => switch (this) {
        CatalogShowKind.listed => 'Listed',
        CatalogShowKind.cached => 'Cached',
        CatalogShowKind.pinned => 'Pinned',
        CatalogShowKind.pending => 'Pending',
        CatalogShowKind.failed => 'Failed',
      };
}

/// Default: every status visible.
const Set<CatalogShowKind> kAllCatalogShowKinds = {
  CatalogShowKind.listed,
  CatalogShowKind.cached,
  CatalogShowKind.pinned,
  CatalogShowKind.pending,
  CatalogShowKind.failed,
};

CatalogShowKind catalogShowKindOf(CatalogFile file) {
  if (file.isUploadFailed) return CatalogShowKind.failed;
  if (file.isUploadPending) return CatalogShowKind.pending;
  return switch (file.availabilityMode) {
    AvailabilityMode.listed => CatalogShowKind.listed,
    AvailabilityMode.cached => CatalogShowKind.cached,
    AvailabilityMode.pinned => CatalogShowKind.pinned,
  };
}

/// Keep files whose status chip category is in [visible].
List<CatalogFile> applyVisibilityFilter(
  List<CatalogFile> files, {
  required Set<CatalogShowKind> visible,
}) {
  if (visible.length >= CatalogShowKind.values.length) return files;
  return files.where((f) => visible.contains(catalogShowKindOf(f))).toList();
}

/// Local catalog search (title / notes / tags).
List<CatalogFile> applyCatalogSearch(
  List<CatalogFile> files, {
  required String query,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return files;
  return files.where((f) {
    if (f.displayName.toLowerCase().contains(needle)) return true;
    if ((f.notes ?? '').toLowerCase().contains(needle)) return true;
    return f.tags.any((t) => t.toLowerCase().contains(needle));
  }).toList();
}
