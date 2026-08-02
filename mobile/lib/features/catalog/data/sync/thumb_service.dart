import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_thumb_store.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:injectable/injectable.dart';

/// Fetches listed-mode JPEG thumbs without materializing full blobs.
@lazySingleton
class ThumbService {
  ThumbService({
    required this.api,
    required this.thumbs,
    required this.log,
  });

  final HomesyncApi api;
  final LocalThumbStore thumbs;
  final AppLog log;

  /// Returns local thumb path when available or freshly downloaded; null if
  /// the file is not an image candidate or the server has no thumb/blob.
  Future<File?> ensureThumb(CatalogFile file) async {
    if (!file.canShowThumb) return null;
    if (file.fileId.startsWith('local:')) return null;

    final existing = await thumbs.pathFor(file.contentHash);
    if (await existing.exists()) return existing;

    try {
      final bytes = await api.getThumb(fileId: file.fileId);
      await thumbs.write(file.contentHash, bytes);
      return thumbs.pathFor(file.contentHash);
    } on HomesyncApiException catch (e) {
      log.warn('thumbs', 'thumb fetch failed for ${file.fileId}: $e');
      return null;
    }
  }

  Future<Uint8List?> readCached(CatalogFile file) {
    return thumbs.read(file.contentHash);
  }
}
