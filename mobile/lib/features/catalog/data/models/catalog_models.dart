import 'package:freezed_annotation/freezed_annotation.dart';

part 'catalog_models.freezed.dart';
part 'catalog_models.g.dart';

/// Phone availability modes (matches server `availability.mode`).
enum AvailabilityMode {
  listed,
  cached,
  pinned;

  static AvailabilityMode parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'pinned':
        return AvailabilityMode.pinned;
      case 'cached':
        return AvailabilityMode.cached;
      case 'listed':
      default:
        return AvailabilityMode.listed;
    }
  }

  String get wire => name;
}

/// Phone→PC upload state for tracked local files (not server availability).
enum LocalUploadState {
  pending,
  failed,
}

/// Freezed lists are unmodifiable; copy so toJson is isolate-safe.
List<String> _tagsToJson(List<String> tags) => List<String>.from(tags);

/// Catalog listing DTOs. Display [CatalogFile.title] may differ from any
/// on-device path or PC `file_paths.relative_path` basename.
@freezed
abstract class CatalogFile with _$CatalogFile {
  const CatalogFile._();

  const factory CatalogFile({
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'content_hash') required String contentHash,
    @JsonKey(name: 'hash_algo') required String hashAlgo,
    @JsonKey(name: 'mime_type') String? mimeType,
    @JsonKey(name: 'size_bytes') required int sizeBytes,
    String? title,
    String? notes,
    @JsonKey(name: 'taken_at') String? takenAt,
    @JsonKey(name: 'created_at') required String createdAt,
    @JsonKey(name: 'updated_at') required String updatedAt,
    @JsonKey(name: 'deleted_at') String? deletedAt,
    @JsonKey(toJson: _tagsToJson) @Default([]) List<String> tags,
    /// Server hint: ``GET /v1/thumbs/{file_id}`` may return a small JPEG.
    @JsonKey(name: 'has_thumb') @Default(false) bool hasThumb,
    /// Local join — not part of server file JSON.
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(AvailabilityMode.listed)
    AvailabilityMode availabilityMode,
    /// True when pin bytes exist under the local blob store.
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(false)
    bool hasLocalBytes,
    /// Best-effort provenance from mirrored `file_paths` (local join).
    @JsonKey(includeFromJson: false, includeToJson: false) String? primarySourceKind,
    /// Local policy: PC tombstone also deletes pin bytes (pinned files only).
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(false)
    bool boundToServer,
    /// Tracked phone file waiting for / failed phone→PC ingest.
    @JsonKey(includeFromJson: false, includeToJson: false)
    LocalUploadState? localUpload,
    /// Absolute device path or catalog relative path for folder browse.
    @JsonKey(includeFromJson: false, includeToJson: false) String? browsePath,
  }) = _CatalogFile;

  factory CatalogFile.fromJson(Map<String, dynamic> json) =>
      _$CatalogFileFromJson(json);

  bool get isDeleted => deletedAt != null;

  bool get isPinned => availabilityMode == AvailabilityMode.pinned;

  bool get isUploadPending => localUpload == LocalUploadState.pending;

  bool get isUploadFailed => localUpload == LocalUploadState.failed;

  /// Listed metadata without local bytes — classic ghost / restore candidate.
  bool get isGhost => !isDeleted && !hasLocalBytes && localUpload == null;

  /// Whether listed-mode thumb fetch is worth attempting.
  bool get canShowThumb =>
      hasThumb || (mimeType?.toLowerCase().startsWith('image/') ?? false);

  /// UI label — not the phone filesystem name (pins use content-hash paths).
  String get displayName {
    if (title != null && title!.trim().isNotEmpty) {
      return title!.trim();
    }
    return fileId;
  }

  /// Chip / status text (availability or local upload state).
  String statusLabel({String? activeUploadPhase}) {
    if (isDeleted) return 'removed';
    if (isUploadFailed) return 'failed';
    if (isUploadPending) {
      final phase = activeUploadPhase?.trim();
      if (phase != null && phase.isNotEmpty) return phase;
      return 'pending';
    }
    return availabilityMode.wire;
  }

  /// e.g. `from WhatsApp · on PC only` for ghost restore UX.
  String? get provenanceSubtitle {
    final from = sourceKindLabel(primarySourceKind);
    final parts = <String>[];
    if (from != null) parts.add(from);
    if (isDeleted) {
      parts.add('removed from PC');
      if (hasLocalBytes) {
        parts.add('still on device');
      }
    } else if (isUploadFailed) {
      parts.add('upload failed');
    } else if (isUploadPending) {
      parts.add('pending upload');
    } else if (isGhost) {
      parts.add('on PC only');
    } else if (hasLocalBytes) {
      parts.add('on device');
    }
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }
}

/// Human label for `file_paths.source_kind` (null = hide in UI).
String? sourceKindLabel(String? kind) {
  switch ((kind ?? '').trim().toLowerCase()) {
    case 'whatsapp':
      return 'from WhatsApp';
    case 'camera':
      return 'from Camera';
    case 'download':
      return 'from Downloads';
    case 'misc':
      return 'from misc';
    case 'manual':
      return 'from manual import';
    default:
      return null;
  }
}

@freezed
abstract class CatalogTag with _$CatalogTag {
  const factory CatalogTag({
    @JsonKey(name: 'tag_id') required String tagId,
    required String name,
    String? color,
  }) = _CatalogTag;

  factory CatalogTag.fromJson(Map<String, dynamic> json) =>
      _$CatalogTagFromJson(json);
}

@freezed
abstract class CatalogFileTag with _$CatalogFileTag {
  const factory CatalogFileTag({
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'tag_id') required String tagId,
  }) = _CatalogFileTag;

  factory CatalogFileTag.fromJson(Map<String, dynamic> json) =>
      _$CatalogFileTagFromJson(json);
}

@freezed
abstract class CatalogAvailability with _$CatalogAvailability {
  const factory CatalogAvailability({
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'device_id') required String deviceId,
    required String mode,
    @JsonKey(name: 'updated_at') required String updatedAt,
  }) = _CatalogAvailability;

  factory CatalogAvailability.fromJson(Map<String, dynamic> json) =>
      _$CatalogAvailabilityFromJson(json);
}

/// Mirrored server `file_paths` row (provenance + path history).
@freezed
abstract class CatalogFilePath with _$CatalogFilePath {
  const factory CatalogFilePath({
    required String id,
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'root_id') String? rootId,
    @JsonKey(name: 'relative_path') required String relativePath,
    @JsonKey(name: 'source_kind') required String sourceKind,
    @JsonKey(name: 'source_device_id') String? sourceDeviceId,
    @JsonKey(name: 'is_current') @Default(true) bool isCurrent,
    @JsonKey(name: 'seen_at') required String seenAt,
    @JsonKey(name: 'gone_at') String? goneAt,
  }) = _CatalogFilePath;

  factory CatalogFilePath.fromJson(Map<String, dynamic> json) =>
      _$CatalogFilePathFromJson(json);
}

@freezed
abstract class CatalogPurge with _$CatalogPurge {
  const factory CatalogPurge({
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'purged_at') required String purgedAt,
  }) = _CatalogPurge;

  factory CatalogPurge.fromJson(Map<String, dynamic> json) =>
      _$CatalogPurgeFromJson(json);
}

@freezed
abstract class CatalogDelta with _$CatalogDelta {
  const factory CatalogDelta({
    @JsonKey(name: 'next_cursor') @Default('') String nextCursor,
    @Default([]) List<CatalogFile> files,
    @Default([]) List<CatalogTag> tags,
    @JsonKey(name: 'file_tags') @Default([]) List<CatalogFileTag> fileTags,
    @Default([]) List<CatalogFilePath> paths,
    @Default([]) List<CatalogAvailability> availability,
    @Default([]) List<CatalogPurge> purged,
    @JsonKey(name: 'next_purge_cursor') @Default('') String nextPurgeCursor,
  }) = _CatalogDelta;

  factory CatalogDelta.fromJson(Map<String, dynamic> json) =>
      _$CatalogDeltaFromJson(json);
}

@freezed
abstract class DeviceInfo with _$DeviceInfo {
  const factory DeviceInfo({
    @JsonKey(name: 'device_id') required String deviceId,
    required String name,
    required String kind,
    @JsonKey(name: 'created_at') required String createdAt,
    @JsonKey(name: 'last_seen_at') String? lastSeenAt,
  }) = _DeviceInfo;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) =>
      _$DeviceInfoFromJson(json);
}

@freezed
abstract class AvailabilityInfo with _$AvailabilityInfo {
  const factory AvailabilityInfo({
    @JsonKey(name: 'file_id') required String fileId,
    @JsonKey(name: 'device_id') required String deviceId,
    required String mode,
    @JsonKey(name: 'updated_at') required String updatedAt,
  }) = _AvailabilityInfo;

  factory AvailabilityInfo.fromJson(Map<String, dynamic> json) =>
      _$AvailabilityInfoFromJson(json);
}

/// Body for ``POST /v1/files`` after a blob PUT.
@freezed
abstract class FileCreateRequest with _$FileCreateRequest {
  const factory FileCreateRequest({
    @JsonKey(name: 'content_hash') required String contentHash,
    @JsonKey(name: 'hash_algo') @Default('blake3') String hashAlgo,
    @JsonKey(name: 'size_bytes') required int sizeBytes,
    @JsonKey(name: 'mime_type') String? mimeType,
    String? title,
    @JsonKey(name: 'taken_at') String? takenAt,
    @JsonKey(name: 'source_kind') @Default('camera') String sourceKind,
    @JsonKey(name: 'source_device_id') String? sourceDeviceId,
    @JsonKey(name: 'relative_path') String? relativePath,
  }) = _FileCreateRequest;

  factory FileCreateRequest.fromJson(Map<String, dynamic> json) =>
      _$FileCreateRequestFromJson(json);
}

/// Body for ``POST /v1/files/{file_id}/content`` (archive head + set new hash).
@freezed
abstract class FileContentRequest with _$FileContentRequest {
  const factory FileContentRequest({
    @JsonKey(name: 'content_hash') required String contentHash,
    @JsonKey(name: 'hash_algo') @Default('blake3') String hashAlgo,
    @JsonKey(name: 'size_bytes') required int sizeBytes,
    String? note,
  }) = _FileContentRequest;

  factory FileContentRequest.fromJson(Map<String, dynamic> json) =>
      _$FileContentRequestFromJson(json);
}
