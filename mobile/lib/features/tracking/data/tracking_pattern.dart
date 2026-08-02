/// Compile user tracking patterns (`*.pdf`) to [RegExp] matchers.
class TrackingPattern {
  TrackingPattern._(this.source, this.regex);

  final String source;
  final RegExp regex;

  /// Accepts simple globs (`*.jpg`) or a regex string.
  ///
  /// Globs: only `*` wildcards; matched against the **basename** (case-insensitive).
  /// Regex: if [raw] contains regex metacharacters beyond a leading glob form,
  /// compiled as a full-path case-insensitive regex.
  static TrackingPattern compile(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('pattern must be non-empty');
    }

    if (_looksLikeSimpleGlob(trimmed)) {
      final escaped = RegExp.escape(trimmed).replaceAll(r'\*', '.*');
      return TrackingPattern._(
        trimmed,
        RegExp('^$escaped\$', caseSensitive: false),
      );
    }

    return TrackingPattern._(
      trimmed,
      RegExp(trimmed, caseSensitive: false),
    );
  }

  bool matchesBasename(String basename) => regex.hasMatch(basename);

  bool matchesPath(String path) {
    final base = path.replaceAll('\\', '/').split('/').last;
    if (_looksLikeSimpleGlob(source)) {
      return matchesBasename(base);
    }
    return regex.hasMatch(path) || matchesBasename(base);
  }

  static bool _looksLikeSimpleGlob(String s) {
    // `*.pdf`, `photo*.jpg`, `*` — no other regex-y chars besides `*`.
    final withoutStars = s.replaceAll('*', '');
    return !withoutStars.contains(RegExp(r'[\\^$+?{}|()[\]]'));
  }
}

String normalizeRuleName(String? raw) {
  final t = (raw ?? '').trim();
  return t.isEmpty ? 'misc' : t;
}
