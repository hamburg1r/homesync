/// Browse modes for the catalog main list (drawer-driven).
enum BrowseMode {
  allCatalog,
  group,
  trackedOnDevice,
  untrackedOnDevice,
  /// Soft-deleted on the PC (`deleted_at` set); may still have local bytes.
  removedFromPc,
}

enum TrackingRuleKind { regex, folder, file }

extension TrackingRuleKindWire on TrackingRuleKind {
  String get wire => name;

  static TrackingRuleKind parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'folder':
        return TrackingRuleKind.folder;
      case 'file':
        return TrackingRuleKind.file;
      case 'regex':
      default:
        return TrackingRuleKind.regex;
    }
  }
}

class TrackingRule {
  const TrackingRule({
    required this.id,
    required this.name,
    required this.kind,
    required this.patternOrUri,
    required this.enabled,
    required this.createdAt,
  });

  final String id;
  final String name;
  final TrackingRuleKind kind;
  final String patternOrUri;
  final bool enabled;
  final String createdAt;

  String get summary {
    switch (kind) {
      case TrackingRuleKind.folder:
      case TrackingRuleKind.file:
        return patternOrUri;
      case TrackingRuleKind.regex:
        return patternOrUri;
    }
  }
}

enum IngestStatus { pending, synced, failed, untracked }

extension IngestStatusWire on IngestStatus {
  String get wire => name;

  static IngestStatus parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'synced':
        return IngestStatus.synced;
      case 'failed':
        return IngestStatus.failed;
      case 'untracked':
        return IngestStatus.untracked;
      case 'pending':
      default:
        return IngestStatus.pending;
    }
  }
}

class LocalTrackedFile {
  const LocalTrackedFile({
    required this.localPath,
    this.ruleId,
    this.fileId,
    this.contentHash,
    this.title,
    required this.sizeBytes,
    this.mtimeMs,
    this.mimeType,
    required this.sourceKind,
    required this.seenAt,
    required this.ingestStatus,
  });

  final String localPath;
  final String? ruleId;
  final String? fileId;
  final String? contentHash;
  final String? title;
  final int sizeBytes;
  /// Milliseconds since epoch; null until first scan after schema v7.
  final int? mtimeMs;
  final String? mimeType;
  final String sourceKind;
  final String seenAt;
  final IngestStatus ingestStatus;

  bool get isTracked => ruleId != null;
  bool get isSynced =>
      ingestStatus == IngestStatus.synced && fileId != null;
}
