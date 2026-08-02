/// Infer `source_kind` provenance from an on-device file path.
String sourceKindFromPath(String path) {
  final norm = path.replaceAll('\\', '/').toLowerCase();
  final parts = norm.split('/');

  if (parts.any((p) => p == 'dcim') || parts.any((p) => p == 'camera')) {
    return 'camera';
  }
  if (norm.contains('/whatsapp/') ||
      norm.contains('/android/media/com.whatsapp') ||
      parts.any((p) => p.contains('whatsapp'))) {
    return 'whatsapp';
  }
  if (parts.any((p) => p == 'download' || p == 'downloads')) {
    return 'download';
  }
  return 'misc';
}
