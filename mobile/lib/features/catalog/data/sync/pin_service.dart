import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';

class PinException implements Exception {
  PinException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Pin = availability update **and** blob materialization (both required).
///
/// Phone-origin tracked files keep bytes at their original path (no app-storage
/// duplicate). Pin store is for PC→phone materialization only.
@lazySingleton
class PinService {
  PinService({
    required this.api,
    required this.repository,
    required this.blobs,
    required this.identity,
    required this.settings,
    required this.log,
  });

  final HomesyncApi api;
  final CatalogRepository repository;
  final LocalBlobStore blobs;
  final DeviceIdentity identity;
  final SettingsStore settings;
  final AppLog log;

  /// Bring to phone = pin availability + materialize blob (ghost restore).
  Future<CatalogFile> bringToPhone(String fileId) => pin(fileId);

  /// Pin a file: set server+local availability to pinned, download bytes.
  Future<CatalogFile> pin(String fileId) async {
    final file = await repository.getFile(fileId);
    if (file == null || file.isDeleted) {
      throw PinException('file not found in local catalog');
    }

    final deviceId = await identity.ensureDeviceId();

    // Already on device at origin path — just mark pinned, no pin-store copy.
    final origin = await repository.originPathForFileId(fileId);
    if (origin != null && await File(origin).exists()) {
      final info = await api.putAvailability(
        fileId: fileId,
        deviceId: deviceId,
        mode: AvailabilityMode.pinned.wire,
      );
      await repository.upsertAvailability(
        fileId: fileId,
        deviceId: deviceId,
        mode: AvailabilityMode.pinned,
        updatedAt: info.updatedAt,
      );
      log.info('pin', 'pinned $fileId (origin path)');
      final refreshed = await repository.getFile(fileId);
      return refreshed ??
          file.copyWith(
            availabilityMode: AvailabilityMode.pinned,
            hasLocalBytes: true,
          );
    }

    await _ensureDiskBudget(file);

    final info = await api.putAvailability(
      fileId: fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.pinned.wire,
    );
    await repository.upsertAvailability(
      fileId: fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.pinned,
      updatedAt: info.updatedAt,
    );

    if (!await blobs.has(file.hashAlgo, file.contentHash)) {
      try {
        final bytes = await api.getBlob(
          algo: file.hashAlgo,
          hexHash: file.contentHash,
        );
        await blobs.write(file.hashAlgo, file.contentHash, bytes);
      } on HomesyncApiException catch (e) {
        log.warn('pin', 'blob missing after pin: $e');
        await api.putAvailability(
          fileId: fileId,
          deviceId: deviceId,
          mode: AvailabilityMode.listed.wire,
        );
        await repository.upsertAvailability(
          fileId: fileId,
          deviceId: deviceId,
          mode: AvailabilityMode.listed,
          updatedAt: DateTime.now().toUtc().toIso8601String(),
        );
        if (e.statusCode == 404) {
          throw PinException(
            'blob missing on PC — cannot materialize',
            statusCode: 404,
          );
        }
        rethrow;
      }
    }

    log.info('pin', 'pinned $fileId');
    final refreshed = await repository.getFile(fileId);
    return refreshed ??
        file.copyWith(
          availabilityMode: AvailabilityMode.pinned,
          hasLocalBytes: true,
        );
  }

  /// Unpin: set listed, delete pin-store bytes only (never deletes origin path).
  Future<CatalogFile> unpin(String fileId) async {
    final file = await repository.getFile(fileId);
    if (file == null) {
      throw PinException('file not found in local catalog');
    }

    final deviceId = await identity.ensureDeviceId();
    final info = await api.putAvailability(
      fileId: fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.listed.wire,
    );
    await repository.upsertAvailability(
      fileId: fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.listed,
      updatedAt: info.updatedAt,
    );
    await blobs.delete(file.hashAlgo, file.contentHash);
    await repository.clearBoundToServer(fileId);
    log.info('pin', 'unpinned $fileId (listing kept; origin untouched)');

    final refreshed = await repository.getFile(fileId);
    return refreshed ??
        file.copyWith(
          availabilityMode: AvailabilityMode.listed,
          hasLocalBytes: false,
        );
  }

  /// Absolute path for open: pin store or phone-origin tracking path.
  Future<String?> resolveLocalPath(CatalogFile file) async {
    if (await blobs.has(file.hashAlgo, file.contentHash)) {
      return (await blobs.pathFor(file.hashAlgo, file.contentHash)).path;
    }
    final origin = await repository.originPathForFileId(file.fileId);
    if (origin != null && await File(origin).exists()) return origin;
    return null;
  }

  /// Open local bytes when present; null when listed-only / missing.
  Future<Uint8List?> openLocalBytes(CatalogFile file) async {
    if (!file.hasLocalBytes &&
        file.availabilityMode != AvailabilityMode.pinned &&
        file.availabilityMode != AvailabilityMode.cached) {
      return null;
    }
    final fromPin = await blobs.read(file.hashAlgo, file.contentHash);
    if (fromPin != null) return fromPin;
    final path = await resolveLocalPath(file);
    if (path == null) return null;
    return File(path).readAsBytes();
  }

  Future<void> _ensureDiskBudget(CatalogFile file) async {
    if (await blobs.has(file.hashAlgo, file.contentHash)) {
      return;
    }
    final used = await blobs.totalBytes();
    final budget = settings.pinBudgetBytes;
    if (used + file.sizeBytes > budget) {
      throw PinException(
        'pin disk budget exceeded '
        '(${_fmt(used + file.sizeBytes)} > ${_fmt(budget)})',
      );
    }
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
