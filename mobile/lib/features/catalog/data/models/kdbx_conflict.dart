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

/// Per-entry keep decision for ``mode=entries`` resolve.
class KdbxEntryChoice {
  const KdbxEntryChoice({required this.entryUuid, required this.keep});

  final String entryUuid;

  /// ``base`` | ``incoming`` | ``discard``
  final String keep;

  Map<String, dynamic> toJson() => {
        'entry_uuid': entryUuid,
        'keep': keep,
      };
}

/// Body for ``POST /v1/conflicts/{id}/resolve``.
class KdbxResolveRequest {
  const KdbxResolveRequest.upload({
    required this.contentHash,
    required this.sizeBytes,
    this.hashAlgo = 'blake3',
    this.note,
  })  : mode = 'upload',
        baseHash = null,
        incomingHash = null,
        choices = const [];

  const KdbxResolveRequest.candidate({
    required this.contentHash,
    required this.sizeBytes,
    this.hashAlgo = 'blake3',
    this.note,
  })  : mode = 'candidate',
        baseHash = null,
        incomingHash = null,
        choices = const [];

  const KdbxResolveRequest.entries({
    required this.baseHash,
    required this.incomingHash,
    required this.choices,
    this.note,
  })  : mode = 'entries',
        contentHash = null,
        hashAlgo = 'blake3',
        sizeBytes = null;

  final String mode;
  final String? contentHash;
  final String hashAlgo;
  final int? sizeBytes;
  final String? note;
  final String? baseHash;
  final String? incomingHash;
  final List<KdbxEntryChoice> choices;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{'mode': mode};
    if (contentHash != null) out['content_hash'] = contentHash;
    out['hash_algo'] = hashAlgo;
    if (sizeBytes != null) out['size_bytes'] = sizeBytes;
    if (note != null) out['note'] = note;
    if (baseHash != null) out['base_hash'] = baseHash;
    if (incomingHash != null) out['incoming_hash'] = incomingHash;
    if (choices.isNotEmpty) {
      out['choices'] = [for (final c in choices) c.toJson()];
    }
    return out;
  }
}

/// Contested entry for interactive merge UI (redacted only).
class KdbxContestedEntry {
  const KdbxContestedEntry({
    required this.entryUuid,
    required this.kind,
    this.identity,
    this.fields = const [],
  });

  final String entryUuid;

  /// ``removed`` | ``added`` | ``modified``
  final String kind;
  final String? identity;
  final List<String> fields;
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

  KdbxConflictCandidate? candidateByRole(String role) {
    for (final c in candidates) {
      if (c.role == role) return c;
    }
    return null;
  }

  bool get hasExtraCandidates =>
      candidates.any((c) => c.role == 'extra');

  /// Entries that need a human choice (removed / added / modified).
  List<KdbxContestedEntry> contestedEntries() {
    final s = diffSummary;
    if (s == null) return const [];
    final out = <KdbxContestedEntry>[];
    final seen = <String>{};

    final removedUuids = s['removed_entry_uuids'] as List<dynamic>? ?? const [];
    final removedPaths = s['removed_entries'] as List<dynamic>? ?? const [];
    for (var i = 0; i < removedUuids.length; i++) {
      final uuid = removedUuids[i].toString().toLowerCase();
      if (uuid.isEmpty || !seen.add(uuid)) continue;
      final identity = i < removedPaths.length ? removedPaths[i].toString() : null;
      out.add(
        KdbxContestedEntry(
          entryUuid: uuid,
          kind: 'removed',
          identity: identity,
        ),
      );
    }

    final addedUuids = s['added_entry_uuids'] as List<dynamic>? ?? const [];
    final addedPaths = s['added_entries'] as List<dynamic>? ?? const [];
    for (var i = 0; i < addedUuids.length; i++) {
      final uuid = addedUuids[i].toString().toLowerCase();
      if (uuid.isEmpty || !seen.add(uuid)) continue;
      final identity = i < addedPaths.length ? addedPaths[i].toString() : null;
      out.add(
        KdbxContestedEntry(
          entryUuid: uuid,
          kind: 'added',
          identity: identity,
        ),
      );
    }

    final modified = s['modified_entries'] as List<dynamic>? ?? const [];
    for (final raw in modified) {
      if (raw is! Map) continue;
      final uuidRaw = raw['uuid'];
      if (uuidRaw == null) continue;
      final uuid = uuidRaw.toString().toLowerCase();
      if (uuid.isEmpty || !seen.add(uuid)) continue;
      final fieldsRaw = raw['fields'];
      final fields = fieldsRaw is List
          ? [for (final f in fieldsRaw) f.toString()]
          : <String>[];
      out.add(
        KdbxContestedEntry(
          entryUuid: uuid,
          kind: 'modified',
          identity: raw['identity']?.toString(),
          fields: fields,
        ),
      );
    }
    return out;
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
