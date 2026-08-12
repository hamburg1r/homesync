/// Phone-only subscription: auto-pin catalog files under a path prefix.
class FolderPinSubscription {
  const FolderPinSubscription({
    required this.id,
    required this.name,
    required this.pathPrefix,
    required this.localRoot,
    required this.enabled,
    required this.createdAt,
  });

  final String id;
  final String name;
  /// Normalized catalog `relative_path` prefix (no trailing slash).
  final String pathPrefix;
  final String localRoot;
  final bool enabled;
  final String createdAt;

  FolderPinSubscription copyWith({
    String? name,
    String? pathPrefix,
    String? localRoot,
    bool? enabled,
  }) {
    return FolderPinSubscription(
      id: id,
      name: name ?? this.name,
      pathPrefix: pathPrefix ?? this.pathPrefix,
      localRoot: localRoot ?? this.localRoot,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }
}

/// Normalize a catalog path prefix for storage / matching.
String normalizeFolderPinPrefix(String raw) {
  var s = raw.trim().replaceAll('\\', '/');
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Whether [relativePath] is exactly [prefix] or a file under that directory.
bool pathMatchesFolderPinPrefix(String relativePath, String prefix) {
  final path = normalizeFolderPinPrefix(relativePath);
  final pfx = normalizeFolderPinPrefix(prefix);
  if (pfx.isEmpty) return false;
  return path == pfx || path.startsWith('$pfx/');
}

/// Path relative to the subscription prefix (for local tree layout).
String pathRelativeToFolderPinPrefix(String relativePath, String prefix) {
  final path = normalizeFolderPinPrefix(relativePath);
  final pfx = normalizeFolderPinPrefix(prefix);
  if (path == pfx) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
  if (path.startsWith('$pfx/')) {
    return path.substring(pfx.length + 1);
  }
  return path;
}
