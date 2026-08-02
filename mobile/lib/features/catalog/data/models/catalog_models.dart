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
    @Default([]) List<String> tags,
    /// Local join — not part of server file JSON.
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(AvailabilityMode.listed)
    AvailabilityMode availabilityMode,
    /// True when pin bytes exist under the local blob store.
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(false)
    bool hasLocalBytes,
  }) = _CatalogFile;

  factory CatalogFile.fromJson(Map<String, dynamic> json) =>
      _$CatalogFileFromJson(json);

  bool get isDeleted => deletedAt != null;

  bool get isPinned => availabilityMode == AvailabilityMode.pinned;

  /// UI label — not the phone filesystem name (pins use content-hash paths).
  String get displayName {
    if (title != null && title!.trim().isNotEmpty) {
      return title!.trim();
    }
    return fileId;
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

@freezed
abstract class CatalogDelta with _$CatalogDelta {
  const factory CatalogDelta({
    @JsonKey(name: 'next_cursor') @Default('') String nextCursor,
    @Default([]) List<CatalogFile> files,
    @Default([]) List<CatalogTag> tags,
    @JsonKey(name: 'file_tags') @Default([]) List<CatalogFileTag> fileTags,
    @Default([]) List<CatalogAvailability> availability,
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
