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
import 'package:path/path.dart' as p;

class PinException implements Exception {
  PinException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Options for where PC→phone bytes land on device.
class PinDestination {
  const PinDestination({this.directory, this.fileName});

  /// Absolute folder; null uses [SettingsStore.pinDestinationDir] or CAS store.
  final String? directory;

  /// Basename under [directory]; null uses catalog display name.
  final String? fileName;
}

/// Pin = availability update **and** blob materialization (both required).
///
/// Phone-origin tracked files keep bytes at their original path (no app-storage
/// duplicate). Pin store / custom destination is for PC→phone materialization.
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
  Future<CatalogFile> bringToPhone(
    String fileId, {
    PinDestination? destination,
  }) =>
      pin(fileId, destination: destination);

  /// Pin a file: set server+local availability to pinned, download bytes.
  Future<CatalogFile> pin(
    String fileId, {
    PinDestination? destination,
  }) async {
    final file = await repository.getFile(fileId);
    if (file == null || file.isDeleted) {
      throw PinException('file not found in local catalog');
    }

    final deviceId = await identity.ensureDeviceId();

    // Already on device at origin path — just mark pinned, no copy.
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

    final existingPin = await repository.pinLocalPathForFileId(fileId);
    if (existingPin != null && await File(existingPin).exists()) {
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
      log.info('pin', 'pinned $fileId (existing local path)');
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

    try {
      await _ensureLocalBytes(file, destination);
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

    log.info('pin', 'pinned $fileId');
    final refreshed = await repository.getFile(fileId);
    return refreshed ??
        file.copyWith(
          availabilityMode: AvailabilityMode.pinned,
          hasLocalBytes: true,
        );
  }

  Future<void> _ensureLocalBytes(
    CatalogFile file,
    PinDestination? destination,
  ) async {
    final useFriendly = _wantsFriendlyPath(destination);
    if (useFriendly) {
      final existing = await repository.pinLocalPathForFileId(file.fileId);
      if (existing != null && await File(existing).exists()) return;
      final bytes = await blobs.read(file.hashAlgo, file.contentHash) ??
          await api.getBlob(algo: file.hashAlgo, hexHash: file.contentHash);
      await _writeMaterialized(file, bytes, destination);
      return;
    }
    if (await blobs.has(file.hashAlgo, file.contentHash)) return;
    final bytes = await api.getBlob(
      algo: file.hashAlgo,
      hexHash: file.contentHash,
    );
    await blobs.write(file.hashAlgo, file.contentHash, bytes);
  }

  bool _wantsFriendlyPath(PinDestination? destination) {
    final override = destination?.directory?.trim();
    if (override != null && override.isNotEmpty) return true;
    final configured = settings.pinDestinationDir;
    return configured != null && configured.isNotEmpty;
  }

  /// Keep on PC only: listed availability + delete every local copy
  /// (CAS pin store, custom pin path, and phone-origin path if present).
  Future<CatalogFile> keepOnPcOnly(String fileId) async {
    final file = await repository.getFile(fileId);
    if (file == null) {
      throw PinException('file not found in local catalog');
    }
    if (fileId.startsWith('local:')) {
      throw PinException('file is not on the PC yet');
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

    await repository.clearPinLocalPath(fileId);
    await blobs.delete(file.hashAlgo, file.contentHash);

    final origin = await repository.originPathForFileId(fileId);
    if (origin != null) {
      final originFile = File(origin);
      if (await originFile.exists()) {
        await originFile.delete();
        log.info('pin', 'deleted origin path $origin');
      }
    }

    await repository.clearBoundToServer(fileId);
    log.info('pin', 'keep on PC only $fileId (local copies removed)');

    final refreshed = await repository.getFile(fileId);
    return refreshed ??
        file.copyWith(
          availabilityMode: AvailabilityMode.listed,
          hasLocalBytes: false,
          boundToServer: false,
        );
  }

  /// Unpin alias kept for tests / older call sites → [keepOnPcOnly]
  /// without deleting phone-origin paths (legacy). Prefer [keepOnPcOnly].
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
    await repository.clearPinLocalPath(fileId);
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

  /// Absolute path for open: origin → custom pin path → CAS pin store.
  Future<String?> resolveLocalPath(CatalogFile file) async {
    final origin = await repository.originPathForFileId(file.fileId);
    if (origin != null && await File(origin).exists()) return origin;
    final pinLocal = await repository.pinLocalPathForFileId(file.fileId);
    if (pinLocal != null && await File(pinLocal).exists()) return pinLocal;
    if (await blobs.has(file.hashAlgo, file.contentHash)) {
      return (await blobs.pathFor(file.hashAlgo, file.contentHash)).path;
    }
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

  Future<void> _writeMaterialized(
    CatalogFile file,
    Uint8List bytes,
    PinDestination? destination,
  ) async {
    final dirPath = destination?.directory?.trim().isNotEmpty == true
        ? destination!.directory!.trim()
        : settings.pinDestinationDir!;

    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    final rawName = (destination?.fileName?.trim().isNotEmpty == true)
        ? destination!.fileName!.trim()
        : file.displayName;
    final safeName = _sanitizeFileName(rawName);
    final dest = await _uniqueFile(dir, safeName);
    await dest.writeAsBytes(bytes, flush: true);
    await repository.setPinLocalPath(file.fileId, dest.path);
    log.info('pin', 'materialized ${file.fileId} → ${dest.path}');
  }

  static String _sanitizeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'file';
    }
    return cleaned;
  }

  static Future<File> _uniqueFile(Directory dir, String name) async {
    var candidate = File(p.join(dir.path, name));
    if (!await candidate.exists()) return candidate;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var i = 1; i < 1000; i++) {
      candidate = File(p.join(dir.path, '$base ($i)$ext'));
      if (!await candidate.exists()) return candidate;
    }
    throw PinException('could not allocate unique filename in ${dir.path}');
  }

  Future<void> _ensureDiskBudget(CatalogFile file) async {
    if (await blobs.has(file.hashAlgo, file.contentHash)) {
      return;
    }
    final pinLocal = await repository.pinLocalPathForFileId(file.fileId);
    if (pinLocal != null && await File(pinLocal).exists()) {
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
