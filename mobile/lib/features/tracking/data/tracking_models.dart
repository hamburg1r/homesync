import 'dart:io';

import 'package:path/path.dart' as p;

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
    this.parentId,
    this.tags = const [],
    this.sourceKind,
    this.bindToServer = false,
    this.children = const [],
  });

  final String id;
  final String name;
  final TrackingRuleKind kind;
  final String patternOrUri;
  final bool enabled;
  final String createdAt;
  /// Set when this is an include-regex under a [TrackingRuleKind.folder] parent.
  final String? parentId;
  final List<String> tags;
  /// Optional ingest `source_kind`; null ⇒ path heuristic.
  final String? sourceKind;
  /// After ingest, mark matches Bound to server (PC tombstone deletes pin).
  final bool bindToServer;
  /// Include-regex children (folder parents only; empty for others).
  final List<TrackingRule> children;

  bool get isChild => parentId != null;

  String get summary {
    switch (kind) {
      case TrackingRuleKind.folder:
      case TrackingRuleKind.file:
      case TrackingRuleKind.regex:
        return patternOrUri;
    }
  }

  TrackingRule copyWith({
    String? id,
    String? name,
    TrackingRuleKind? kind,
    String? patternOrUri,
    bool? enabled,
    String? createdAt,
    String? parentId,
    List<String>? tags,
    String? sourceKind,
    bool? bindToServer,
    List<TrackingRule>? children,
    bool clearParentId = false,
    bool clearSourceKind = false,
  }) {
    return TrackingRule(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      patternOrUri: patternOrUri ?? this.patternOrUri,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      parentId: clearParentId ? null : (parentId ?? this.parentId),
      tags: tags ?? this.tags,
      sourceKind: clearSourceKind ? null : (sourceKind ?? this.sourceKind),
      bindToServer: bindToServer ?? this.bindToServer,
      children: children ?? this.children,
    );
  }
}

/// Result of matching a local path against tracking rules.
class TrackingRuleMatch {
  const TrackingRuleMatch({
    required this.rule,
    this.folderParent,
    this.folderRoot,
    this.contributing = const [],
  });

  /// Most specific rule (child include-regex, or the top-level rule).
  final TrackingRule rule;
  /// Folder parent when [rule] is a child include-regex.
  final TrackingRule? folderParent;
  /// Absolute folder root when matched under a folder rule.
  final String? folderRoot;
  /// All rules that hit this path (for tag union / source_kind precedence).
  final List<TrackingRule> contributing;

  String get displayName => folderParent?.name ?? rule.name;

  List<TrackingRule> get _tagSources {
    if (contributing.isNotEmpty) return contributing;
    return [
      ?folderParent,
      rule,
    ];
  }

  List<String> get effectiveTags {
    final out = <String>{};
    for (final r in _tagSources) {
      out.addAll(r.tags);
    }
    return out.toList()..sort();
  }

  /// Most-specific override: file > folder-child > folder > top-level regex.
  String? get sourceKindOverride {
    TrackingRule? best;
    var bestRank = -1;
    for (final r in _tagSources) {
      if (r.sourceKind == null || r.sourceKind!.trim().isEmpty) continue;
      final rank = _sourceKindRank(r);
      if (rank > bestRank) {
        bestRank = rank;
        best = r;
      }
    }
    return best?.sourceKind;
  }

  /// True if any matching rule requests Bound to server after ingest.
  bool get effectiveBindToServer =>
      _tagSources.any((r) => r.bindToServer);
}

int _sourceKindRank(TrackingRule r) {
  if (r.kind == TrackingRuleKind.file) return 40;
  if (r.parentId != null) return 30; // folder include-child
  if (r.kind == TrackingRuleKind.folder) return 20;
  if (r.kind == TrackingRuleKind.regex) return 10;
  return 0;
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

/// Flat id → rule map including folder children.
Map<String, TrackingRule> indexTrackingRules(Iterable<TrackingRule> forest) {
  final out = <String, TrackingRule>{};
  for (final r in forest) {
    out[r.id] = r;
    for (final c in r.children) {
      out[c.id] = c;
    }
  }
  return out;
}

class TrackingIngestMeta {
  const TrackingIngestMeta({
    required this.relativePath,
    required this.tags,
  });

  final String relativePath;
  final List<String> tags;
}

/// Build catalog `relative_path` + effective tags for a tracked local row.
TrackingIngestMeta resolveTrackingIngestMeta(
  Map<String, TrackingRule> byId,
  LocalTrackedFile row, {
  TrackingRuleMatch? match,
}) {
  final ruleId = row.ruleId;
  final rule = ruleId == null ? null : byId[ruleId];
  final parent = rule?.parentId == null ? null : byId[rule!.parentId!];
  final folder = rule?.kind == TrackingRuleKind.folder
      ? rule
      : (parent?.kind == TrackingRuleKind.folder ? parent : null);
  final displayName = folder?.name ?? rule?.name ?? 'misc';
  final tags = match?.effectiveTags ??
      (<String>{
        ...?folder?.tags,
        ...?rule?.tags,
      }.toList()
        ..sort());

  final folderRoot = match?.folderRoot ?? folder?.patternOrUri;
  final relativePath = buildTrackRelativePath(
    ruleName: displayName,
    localPath: row.localPath,
    folderRoot: folderRoot,
  );
  return TrackingIngestMeta(relativePath: relativePath, tags: tags);
}

/// `track/<ruleName>/<basename>` or `track/<ruleName>/<rel under folder>`.
String buildTrackRelativePath({
  required String ruleName,
  required String localPath,
  String? folderRoot,
}) {
  final name = ruleName.trim().isEmpty ? 'misc' : ruleName.trim();
  if (folderRoot != null && folderRoot.trim().isNotEmpty) {
    final root = p.normalize(folderRoot);
    final norm = p.normalize(localPath);
    final String rel;
    if (norm == root) {
      rel = p.basename(norm);
    } else if (norm.startsWith('$root/') ||
        norm.startsWith('$root${Platform.pathSeparator}')) {
      rel = p.relative(norm, from: root).replaceAll('\\', '/');
    } else {
      rel = p.basename(norm);
    }
    return 'track/$name/$rel';
  }
  return 'track/$name/${p.basename(localPath)}';
}
