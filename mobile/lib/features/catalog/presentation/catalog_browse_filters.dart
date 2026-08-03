import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';

/// Keep files that have local bytes and are not tombstoned.
List<CatalogFile> applyDeviceSyncedFilter(
  List<CatalogFile> files, {
  required bool enabled,
}) {
  if (!enabled) return files;
  return files.where((f) => f.hasLocalBytes && !f.isDeleted).toList();
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
