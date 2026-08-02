import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:injectable/injectable.dart';

/// Top-level callback required by [FlutterForegroundTask.startService].
///
/// The task isolate only keeps the Android process alive; ingest work runs on
/// the main isolate (where DI / Drift already live).
@pragma('vm:entry-point')
void homesyncIngestTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_HomesyncKeepAliveTaskHandler());
}

class _HomesyncKeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}
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
      allowAutoRestart: false,
      stopWithTask: true,
    ),
  );
}

/// Runs phone→PC ingest without blocking catalog refresh / UI.
///
/// On Android, starts a `dataSync` foreground service so uploads can continue
/// while the app is backgrounded (notification stays visible).
@lazySingleton
class BackgroundIngestRunner {
  BackgroundIngestRunner({
    required this.scanner,
    required this.ingest,
    required this.log,
  });

  final DeviceScanner scanner;
  final IngestService ingest;
  final AppLog log;

  Future<void>? _inFlight;
  bool get isRunning => _inFlight != null;

  /// Kick a background batch if one is not already running.
  Future<void> kick({
    IngestProgressCallback? onProgress,
    Future<void> Function()? onFinished,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _run(onProgress: onProgress, onFinished: onFinished);
    _inFlight = future.whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<void> _run({
    IngestProgressCallback? onProgress,
    Future<void> Function()? onFinished,
  }) async {
    final startedService = await _startForegroundService();
    try {
      void report(IngestFileProgress p) {
        onProgress?.call(p);
        unawaited(_updateNotification(p));
      }

      final flushed = await ingest.flushPending(onProgress: report);
      final ingested = await scanner.ingestPending(onProgress: report);
      log.info(
        'ingest',
        'background batch done flushed=$flushed ingested=$ingested',
      );
    } finally {
      if (startedService) {
        await _stopForegroundService();
      }
      try {
        await onFinished?.call();
      } catch (e) {
        log.warn('ingest', 'onFinished failed: $e');
      }
    }
  }

  Future<bool> _startForegroundService() async {
    if (!Platform.isAndroid) return false;
    try {
      final permission = await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) {
        return true;
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 1101,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Homesync uploading',
        notificationText: 'Sending files to your PC…',
        callback: homesyncIngestTaskCallback,
      );
      if (result is ServiceRequestFailure) {
        log.warn('ingest', 'foreground service start failed: ${result.error}');
        return false;
      }
      return true;
    } catch (e) {
      log.warn('ingest', 'foreground service unavailable: $e');
      return false;
    }
  }

  Future<void> _updateNotification(IngestFileProgress p) async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Homesync ${p.phase}',
        notificationText: '${p.index}/${p.total}: ${p.title}',
      );
    } catch (_) {
      // Best-effort; upload continues even if notification update fails.
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      log.warn('ingest', 'foreground service stop failed: $e');
    }
  }
}
