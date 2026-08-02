import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';

enum SyncOutcome { ok, failed }

class SyncResult {
  const SyncResult({
    required this.outcome,
    this.error,
    this.pages = 0,
    this.filesTouched = 0,
    this.ingestsFlushed = 0,
  });

  final SyncOutcome outcome;
  final Object? error;
  final int pages;
  final int filesTouched;
  final int ingestsFlushed;

  bool get ok => outcome == SyncOutcome.ok;
}

/// Registers the device, then pulls catalog deltas into the local mirror.
@lazySingleton
class CatalogSync {
  CatalogSync({
    required this.api,
    required this.repository,
    required this.identity,
    required this.settings,
    required this.ingest,
    required this.log,
  });

  final HomesyncApi api;
  final CatalogRepository repository;
  final DeviceIdentity identity;
  final SettingsStore settings;
  final IngestService ingest;
  final AppLog log;

  Future<SyncResult>? _inFlight;

  /// Concurrent callers share one in-flight sync (mutex).
  Future<SyncResult> sync({
    int pageLimit = 500,
    IngestProgressCallback? onIngestProgress,
    bool flushIngestQueue = true,
  }) {
    if (_inFlight != null) {
      log.fine('sync', 'joining in-flight sync');
      return _inFlight!;
    }
    final future = _doSync(
      pageLimit: pageLimit,
      onIngestProgress: onIngestProgress,
      flushIngestQueue: flushIngestQueue,
    );
    _inFlight = future.whenComplete(() {
      _inFlight = null;
    });
    return _inFlight!;
  }

  /// Bind this install to [deviceId], clear stale local availability, full re-sync.
  Future<SyncResult> reclaimDevice(String deviceId) async {
    final old = identity.currentDeviceId;
    if (old != null && old != deviceId.trim()) {
      await repository.clearAvailabilityForDevice(old);
    }
    await identity.reclaim(deviceId);
    await repository.clearDeltaCursor();
    log.info('sync', 'reclaim device → ${deviceId.trim()}; full catalog pull');
    return sync();
  }

  /// Mint a new device UUID on this install and re-register + sync.
  Future<SyncResult> resetDeviceIdentity() async {
    final old = identity.currentDeviceId;
    if (old != null) {
      await repository.clearAvailabilityForDevice(old);
    }
    final id = await identity.resetToNew();
    await repository.clearDeltaCursor();
    log.info('sync', 'reset device → $id; full catalog pull');
    return sync();
  }

  Future<SyncResult> _doSync({
    required int pageLimit,
    IngestProgressCallback? onIngestProgress,
    bool flushIngestQueue = true,
  }) async {
    api.refreshBaseUrlFromSettings();
    try {
      final deviceId = await identity.ensureDeviceId();
      await api.registerDevice(
        deviceId: deviceId,
        name: settings.deviceName,
      );

      // Blobs first (queue order), then pull catalog — unless deferred to
      // BackgroundIngestRunner so UI refresh is not blocked by uploads.
      final flushed = flushIngestQueue
          ? await ingest.flushPending(onProgress: onIngestProgress)
          : 0;

      var cursor = await repository.getDeltaCursor();
      var pages = 0;
      var filesTouched = 0;

      while (true) {
        final delta = await api.catalogDelta(since: cursor, limit: pageLimit);
        pages += 1;
        filesTouched += delta.files.length;
        await repository.applyDelta(delta);

        final next = delta.nextCursor;
        final progressed = next.isNotEmpty && next != cursor;
        final hasRows = delta.files.isNotEmpty;
        cursor = next.isEmpty ? cursor : next;

        if (!hasRows || !progressed || delta.files.length < pageLimit) {
          break;
        }
      }

      log.info(
        'sync',
        'ok pages=$pages filesTouched=$filesTouched '
        'ingestsFlushed=$flushed cursor=$cursor',
      );
      return SyncResult(
        outcome: SyncOutcome.ok,
        pages: pages,
        filesTouched: filesTouched,
        ingestsFlushed: flushed,
      );
    } catch (e, st) {
      log.error('sync', 'failed', e, st);
      return SyncResult(outcome: SyncOutcome.failed, error: e);
    }
  }
}
