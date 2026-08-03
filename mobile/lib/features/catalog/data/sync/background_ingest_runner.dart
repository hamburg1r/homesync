import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:injectable/injectable.dart';

/// Top-level callback required by [FlutterForegroundTask.startService].
///
/// Upload HTTP runs **here** (task isolate) with jobs prepared by the main
/// isolate. Do **not** open Drift / SharedPreferences here — dual-isolate DB
/// access caused flush failures; main owns catalog writes.
@pragma('vm:entry-point')
void homesyncIngestTaskCallback() {
  FlutterForegroundTask.setTaskHandler(HomesyncIngestTaskHandler());
}

class HomesyncIngestTaskHandler extends TaskHandler {
  bool _batchRunning = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map['type'] == 'run') {
        unawaited(_runJobs(map));
      }
    } else if (data == 'kick' || data == 'run') {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': 'task isolate expected job payload; got kick-only',
      });
    }
  }

  Future<void> _runJobs(Map<String, dynamic> payload) async {
    if (_batchRunning) return;
    _batchRunning = true;
    final api = HomesyncApi.detached(
      baseUrl: payload['baseUrl'] as String? ?? '',
      log: AppLog(),
    );
    try {
      final deviceId = payload['deviceId'] as String? ?? '';
      final rawJobs = payload['jobs'] as List<dynamic>? ?? const [];
      final jobs = rawJobs
          .map((e) => IngestQueueItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();

      for (var i = 0; i < jobs.length; i++) {
        final item = jobs[i];
        try {
          final result = await _uploadOne(
            api: api,
            item: item,
            deviceId: deviceId,
            index: i + 1,
            total: jobs.length,
          );
          FlutterForegroundTask.sendDataToMain({
            'type': 'item_ok',
            'id': item.id,
            'file': result.file.toJson(),
            'availability': result.availability.toJson(),
          });
        } catch (e) {
          FlutterForegroundTask.sendDataToMain({
            'type': 'item_err',
            'id': item.id,
            'message': e.toString(),
          });
          // Stop the batch on first failure (matches flushPending).
          break;
        }
      }
      FlutterForegroundTask.sendDataToMain({'type': 'done'});
    } catch (e, st) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': e.toString(),
        'stack': st.toString(),
      });
    } finally {
      _batchRunning = false;
      api.close();
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
  }

  Future<({CatalogFile file, AvailabilityInfo availability})> _uploadOne({
    required HomesyncApi api,
    required IngestQueueItem item,
    required String deviceId,
    required int index,
    required int total,
  }) async {
    final display = item.title ?? item.contentHash;
    final sourcePath = item.sourcePath;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw IngestException('missing source_path for queued ingest ${item.id}');
    }
    final bytesFile = File(sourcePath);
    if (!await bytesFile.exists()) {
      throw IngestException(
        'local blob missing for queued ingest ${item.contentHash}',
      );
    }

    await api.putBlobResumable(
      algo: item.hashAlgo,
      hexHash: item.contentHash,
      contentLength: item.sizeBytes,
      readAt: (offset, length) async {
        final raf = await bytesFile.open();
        try {
          await raf.setPosition(offset);
          return await raf.read(length);
        } finally {
          await raf.close();
        }
      },
      onProgress: (sent, totalBytes) {
        FlutterForegroundTask.sendDataToMain({
          'type': 'progress',
          'title': display,
          'index': index,
          'total': total,
          'phase': 'uploading',
          'fraction': totalBytes == 0 ? 1.0 : sent / totalBytes,
        });
        unawaited(
          FlutterForegroundTask.updateService(
            notificationTitle: 'Homesync uploading',
            notificationText: '$index/$total: $display',
          ),
        );
      },
    );

    FlutterForegroundTask.sendDataToMain({
      'type': 'progress',
      'title': display,
      'index': index,
      'total': total,
      'phase': 'finishing',
      'fraction': 0.5,
    });

    final created = await api.createFile(
      FileCreateRequest(
        contentHash: item.contentHash,
        hashAlgo: item.hashAlgo,
        sizeBytes: item.sizeBytes,
        mimeType: item.mimeType,
        title: item.title,
        sourceKind: item.sourceKind,
        sourceDeviceId: deviceId,
        relativePath: item.relativePath,
      ),
    );

    final avail = await api.putAvailability(
      fileId: created.fileId,
      deviceId: deviceId,
      mode: AvailabilityMode.pinned.wire,
    );

    return (file: created, availability: avail);
  }
}

/// Configure notification / FG options once at app start.
void initBackgroundIngestService() {
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'homesync_ingest',
      channelName: 'Homesync uploads',
      channelDescription: 'Uploading files from this phone to the PC catalog',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
      allowAutoRestart: true,
      stopWithTask: true,
    ),
  );
}

/// Runs phone→PC ingest without blocking catalog refresh / UI.
///
/// On Android, HTTP runs in the `dataSync` task isolate with jobs prepared on
/// the main isolate (hash + queue + Drift commits stay on main).
@lazySingleton
class BackgroundIngestRunner {
  BackgroundIngestRunner({
    required this.scanner,
    required this.ingest,
    required this.settings,
    required this.identity,
    required this.log,
  }) {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  final DeviceScanner scanner;
  final IngestService ingest;
  final SettingsStore settings;
  final DeviceIdentity identity;
  final AppLog log;

  Future<void>? _inFlight;
  Completer<void>? _taskDone;
  IngestProgressCallback? _onProgress;
  Future<void> Function()? _onFinished;
  Map<String, IngestQueueItem> _jobsById = {};
  Future<void> _commitChain = Future<void>.value();

  bool get isRunning => _inFlight != null;

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);
    switch (map['type']) {
      case 'progress':
        final p = IngestFileProgress(
          title: map['title'] as String? ?? 'upload',
          index: map['index'] as int? ?? 1,
          total: map['total'] as int? ?? 1,
          phase: map['phase'] as String? ?? 'uploading',
          fraction: (map['fraction'] as num?)?.toDouble() ?? 0,
        );
        _onProgress?.call(p);
      case 'item_ok':
        _commitChain = _commitChain.then((_) => _commitItemOk(map));
      case 'item_err':
        log.warn(
          'ingest',
          'flush failed for ${map['id']}: ${map['message']}',
        );
      case 'done':
      case 'error':
        if (map['type'] == 'error') {
          log.warn('ingest', 'task-isolate error: ${map['message']}');
        }
        final c = _taskDone;
        if (c != null && !c.isCompleted) {
          unawaited(
            _commitChain.whenComplete(() {
              if (!c.isCompleted) c.complete();
            }),
          );
        }
    }
  }

  Future<void> _commitItemOk(Map<String, dynamic> map) async {
    final id = map['id'] as String?;
    final item = id == null ? null : _jobsById[id];
    if (item == null) {
      log.warn('ingest', 'item_ok for unknown job $id');
      return;
    }
    try {
      final fileJson = Map<String, dynamic>.from(map['file'] as Map);
      final availJson = Map<String, dynamic>.from(map['availability'] as Map);
      final created = CatalogFile.fromJson(fileJson);
      final avail = AvailabilityInfo.fromJson(availJson);
      await ingest.commitRemoteIngest(
        item: item,
        created: created,
        availability: avail,
      );
      final path = item.sourcePath;
      if (path != null) {
        await scanner.repository.markSynced(
          localPath: path,
          fileId: created.fileId,
          contentHash: created.contentHash,
        );
      }
      log.info('ingest', 'ingested ${created.fileId} (${item.title ?? item.contentHash})');
    } catch (e) {
      log.warn('ingest', 'commit after upload failed for $id: $e');
    }
  }

  /// Start the Android FG keep-alive while still in the foreground.
  ///
  /// Call at the beginning of refresh so Home during scan/upload is covered.
  Future<void> ensureKeepAlive() async {
    if (!Platform.isAndroid) return;
    await _requestNotificationPermission();
    if (await FlutterForegroundTask.isRunningService) return;
    final result = await FlutterForegroundTask.startService(
      serviceId: 1101,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Homesync syncing',
      notificationText: 'Preparing uploads…',
      callback: homesyncIngestTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      log.warn('ingest', 'keep-alive service start failed: ${result.error}');
    }
  }

  /// Kick a background batch if one is not already running.
  Future<void> kick({
    IngestProgressCallback? onProgress,
    Future<void> Function()? onFinished,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = Platform.isAndroid
        ? _runViaTaskIsolate(onProgress: onProgress, onFinished: onFinished)
        : _runOnCallerIsolate(onProgress: onProgress, onFinished: onFinished);
    _inFlight = future.whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<void> _runViaTaskIsolate({
    IngestProgressCallback? onProgress,
    Future<void> Function()? onFinished,
  }) async {
    _onProgress = onProgress;
    _onFinished = onFinished;
    _taskDone = Completer<void>();
    try {
      await ensureKeepAlive();
      if (!await FlutterForegroundTask.isRunningService) {
        log.warn('ingest', 'FG service not running — uploading on UI isolate');
        await _runOnCallerIsolate(
          onProgress: onProgress,
          onFinished: onFinished,
        );
        return;
      }

      // Hash + enqueue on main (Drift / prefs). Task isolate only does HTTP.
      void report(IngestFileProgress p) => onProgress?.call(p);
      await scanner.enqueuePending(onProgress: report);
      final jobs = await ingest.queue.list();
      if (jobs.isEmpty) {
        log.info('ingest', 'task-isolate: nothing to upload');
        if (!(_taskDone?.isCompleted ?? true)) {
          _taskDone!.complete();
        }
        return;
      }
      _jobsById = {for (final j in jobs) j.id: j};
      final deviceId = await identity.ensureDeviceId();
      FlutterForegroundTask.sendDataToTask({
        'type': 'run',
        'baseUrl': settings.baseUrl,
        'deviceId': deviceId,
        'jobs': jobs.map((j) => j.toJson()).toList(),
      });
      await _taskDone!.future.timeout(
        const Duration(hours: 6),
        onTimeout: () {
          log.warn('ingest', 'task-isolate batch timed out');
        },
      );
    } finally {
      _onProgress = null;
      _jobsById = {};
      _commitChain = Future<void>.value();
      try {
        await _onFinished?.call();
      } catch (e) {
        log.warn('ingest', 'onFinished failed: $e');
      }
      _onFinished = null;
      _taskDone = null;
    }
  }

  Future<void> _runOnCallerIsolate({
    IngestProgressCallback? onProgress,
    Future<void> Function()? onFinished,
  }) async {
    try {
      void report(IngestFileProgress p) => onProgress?.call(p);
      final flushed = await ingest.flushPending(onProgress: report);
      final ingested = await scanner.ingestPending(onProgress: report);
      log.info(
        'ingest',
        'caller-isolate batch done flushed=$flushed ingested=$ingested',
      );
    } finally {
      try {
        await onFinished?.call();
      } catch (e) {
        log.warn('ingest', 'onFinished failed: $e');
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      log.warn('ingest', 'notification permission request failed: $e');
    }
  }
}
