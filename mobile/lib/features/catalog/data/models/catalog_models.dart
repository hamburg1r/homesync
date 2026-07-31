import 'package:freezed_annotation/freezed_annotation.dart';

part 'catalog_models.freezed.dart';
part 'catalog_models.g.dart';

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
  }) = _CatalogFile;

  factory CatalogFile.fromJson(Map<String, dynamic> json) =>
      _$CatalogFileFromJson(json);

  bool get isDeleted => deletedAt != null;

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
abstract class CatalogDelta with _$CatalogDelta {
  const factory CatalogDelta({
    @JsonKey(name: 'next_cursor') @Default('') String nextCursor,
    @Default([]) List<CatalogFile> files,
    @Default([]) List<CatalogTag> tags,
    @JsonKey(name: 'file_tags') @Default([]) List<CatalogFileTag> fileTags,
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
