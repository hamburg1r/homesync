import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:injectable/injectable.dart';

/// Top-level callback required by [FlutterForegroundTask.startService].
///
/// Upload work runs **here** (task isolate), not on the UI isolate — otherwise
/// pressing Home pauses the engine and aborts in-flight HTTP.
@pragma('vm:entry-point')
void homesyncIngestTaskCallback() {
  FlutterForegroundTask.setTaskHandler(HomesyncIngestTaskHandler());
}

class HomesyncIngestTaskHandler extends TaskHandler {
  bool _batchRunning = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Service may start idle (keep-alive). Wait for an explicit kick, but if
    // the main isolate already sent one before onStart ran, run immediately
    // when asked via onReceiveData.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {
    if (data == 'kick' || data == 'run') {
      unawaited(_runBatch());
    }
  }

  Future<void> _runBatch() async {
    if (_batchRunning) return;
    _batchRunning = true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await configureDependencies();
      final log = getIt<AppLog>();
      final ingest = getIt<IngestService>();
      final scanner = getIt<DeviceScanner>();

      void report(IngestFileProgress p) {
        FlutterForegroundTask.sendDataToMain({
          'type': 'progress',
          'title': p.title,
          'index': p.index,
          'total': p.total,
          'phase': p.phase,
          'fraction': p.fraction,
        });
        unawaited(
          FlutterForegroundTask.updateService(
            notificationTitle: 'Homesync ${p.phase}',
            notificationText: '${p.index}/${p.total}: ${p.title}',
          ),
        );
      }

      final flushed = await ingest.flushPending(onProgress: report);
      final ingested = await scanner.ingestPending(onProgress: report);
      log.info(
        'ingest',
        'task-isolate batch done flushed=$flushed ingested=$ingested',
      );
      FlutterForegroundTask.sendDataToMain({'type': 'done'});
    } catch (e, st) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': e.toString(),
        'stack': st.toString(),
      });
    } finally {
      _batchRunning = false;
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
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
/// On Android, uploads execute inside the `dataSync` foreground-task isolate so
/// pressing Home does not abort HTTP. Non-Android (tests) runs on-isolate.
@lazySingleton
class BackgroundIngestRunner {
  BackgroundIngestRunner({
    required this.scanner,
    required this.ingest,
    required this.log,
  }) {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  final DeviceScanner scanner;
  final IngestService ingest;
  final AppLog log;

  Future<void>? _inFlight;
  Completer<void>? _taskDone;
  IngestProgressCallback? _onProgress;
  Future<void> Function()? _onFinished;

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
      case 'done':
      case 'error':
        if (map['type'] == 'error') {
          log.warn('ingest', 'task-isolate error: ${map['message']}');
        }
        final c = _taskDone;
        if (c != null && !c.isCompleted) {
          c.complete();
        }
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
        // Fall back so uploads still happen if FG start was denied.
        log.warn('ingest', 'FG service not running — uploading on UI isolate');
        await _runOnCallerIsolate(
          onProgress: onProgress,
          onFinished: onFinished,
        );
        return;
      }
      FlutterForegroundTask.sendDataToTask('kick');
      await _taskDone!.future.timeout(
        const Duration(hours: 6),
        onTimeout: () {
          log.warn('ingest', 'task-isolate batch timed out');
        },
      );
    } finally {
      _onProgress = null;
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
