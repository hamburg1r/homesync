/// KeePass conflict outbox DTOs (plain JSON; no freezed).
library;

class KdbxConflictCandidate {
  const KdbxConflictCandidate({
    required this.contentHash,
    required this.sizeBytes,
    this.sourceDeviceId,
    required this.role,
    required this.createdAt,
  });

  final String contentHash;
  final int sizeBytes;
  final String? sourceDeviceId;
  final String role;
  final String createdAt;

  factory KdbxConflictCandidate.fromJson(Map<String, dynamic> json) {
    return KdbxConflictCandidate(
      contentHash: json['content_hash'] as String,
      sizeBytes: json['size_bytes'] as int,
      sourceDeviceId: json['source_device_id'] as String?,
      role: json['role'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}

class KdbxConflict {
  const KdbxConflict({
    required this.conflictId,
    required this.fileId,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.diffSummary,
    this.resolvedContentHash,
    this.candidates = const [],
  });

  final String conflictId;
  final String fileId;
  final String state;
  final String createdAt;
  final String updatedAt;
  final Map<String, dynamic>? diffSummary;
  final String? resolvedContentHash;
  final List<KdbxConflictCandidate> candidates;

  factory KdbxConflict.fromJson(Map<String, dynamic> json) {
    final cands = json['candidates'] as List<dynamic>? ?? const [];
    final summary = json['diff_summary'];
    return KdbxConflict(
      conflictId: json['conflict_id'] as String,
      fileId: json['file_id'] as String,
      state: json['state'] as String,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      diffSummary: summary is Map<String, dynamic> ? summary : null,
      resolvedContentHash: json['resolved_content_hash'] as String?,
      candidates: [
        for (final e in cands)
          KdbxConflictCandidate.fromJson(e as Map<String, dynamic>),
      ],
    );
  }

  String get redactedDiffLabel {
    final s = diffSummary;
    if (s == null) return state;
    final classification = s['classification'] as String? ?? state;
    final modified = s['modified_entries'] as List<dynamic>? ?? const [];
    final added = s['added_entries'] as List<dynamic>? ?? const [];
    final removed = s['removed_entries'] as List<dynamic>? ?? const [];
    if (classification == 'needs_secret') {
      return 'Needs vault password on PC';
    }
    if (classification == 'trivial') return 'Trivial (auto)';
    final parts = <String>[
      if (modified.isNotEmpty) '${modified.length} modified',
      if (added.isNotEmpty) '${added.length} added',
      if (removed.isNotEmpty) '${removed.length} removed',
    ];
    if (parts.isEmpty) return classification;
    return parts.join(', ');
  }
}

/// Thrown when ``POST …/content`` returns 202 with an open outbox.
class KdbxConflictPendingException implements Exception {
  KdbxConflictPendingException(this.conflict);

  final KdbxConflict conflict;

  @override
  String toString() =>
      'KeePass conflict ${conflict.conflictId} (${conflict.state})';
}
