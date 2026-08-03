import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:path/path.dart' as p;

/// One row in folder browse mode (a subdirectory or a file at this level).
sealed class CatalogTreeRow {
  const CatalogTreeRow();
}

final class CatalogTreeFolderRow extends CatalogTreeRow {
  const CatalogTreeFolderRow({
    required this.name,
    required this.prefix,
    required this.fileCount,
    required this.pendingCount,
  });

  final String name;
  /// Browse-path prefix for this folder (no trailing slash).
  final String prefix;
  final int fileCount;
  final int pendingCount;

  bool get hasPending => pendingCount > 0;
}

final class CatalogTreeFileRow extends CatalogTreeRow {
  const CatalogTreeFileRow(this.file);

  final CatalogFile file;
}

String? fileExtensionOf(CatalogFile file) {
  final fromPath = file.browsePath;
  final name = (fromPath != null && fromPath.trim().isNotEmpty)
      ? p.basename(fromPath)
      : file.displayName;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot >= name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// Extension labels present in [files] (sorted).
List<String> extensionsInFiles(Iterable<CatalogFile> files) {
  final out = <String>{};
  for (final f in files) {
    final ext = fileExtensionOf(f);
    if (ext != null) out.add(ext);
  }
  return out.toList()..sort();
}

List<CatalogFile> applyHiddenExtensions(
  List<CatalogFile> files, {
  required Set<String> hidden,
}) {
  if (hidden.isEmpty) return files;
  final hide = {for (final e in hidden) e.toLowerCase()};
  return files.where((f) {
    final ext = fileExtensionOf(f);
    if (ext == null) return true;
    return !hide.contains(ext);
  }).toList();
}

/// Build folder/file rows for [treePrefix] (empty = roots of browse paths).
List<CatalogTreeRow> buildTreeRows({
  required List<CatalogFile> files,
  required String treePrefix,
}) {
  final prefix = treePrefix.trim();
  final prefixWithSep = prefix.isEmpty ? '' : (prefix.endsWith('/') ? prefix : '$prefix/');

  final folders = <String, ({int files, int pending})>{};
  final atLevel = <CatalogFile>[];

  for (final file in files) {
    final raw = (file.browsePath ?? file.displayName).replaceAll('\\', '/');
    final path = raw.startsWith('/') ? raw.substring(1) : raw;
    if (prefix.isNotEmpty) {
      if (path != prefix && !path.startsWith(prefixWithSep)) continue;
    }
    final rel = prefix.isEmpty
        ? path
        : (path == prefix ? '' : path.substring(prefixWithSep.length));
    if (rel.isEmpty) {
      // Exact folder path shouldn't appear as a file.
      continue;
    }
    final slash = rel.indexOf('/');
    if (slash < 0) {
      atLevel.add(file);
      continue;
    }
    final folderName = rel.substring(0, slash);
    final key = prefix.isEmpty ? folderName : '$prefix/$folderName';
    final prev = folders[key] ?? (files: 0, pending: 0);
    folders[key] = (
      files: prev.files + 1,
      pending: prev.pending + (file.isUploadPending || file.isUploadFailed ? 1 : 0),
    );
  }

  final rows = <CatalogTreeRow>[
    for (final e in (folders.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()))))
      CatalogTreeFolderRow(
        name: p.basename(e.key),
        prefix: e.key,
        fileCount: e.value.files,
        pendingCount: e.value.pending,
      ),
    for (final f in (atLevel.toList()
      ..sort(
        (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      )))
      CatalogTreeFileRow(f),
  ];
  return rows;
}
