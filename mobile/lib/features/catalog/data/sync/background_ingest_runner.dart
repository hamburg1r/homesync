import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Top-level callback required by [FlutterForegroundTask.startService].
///
/// Hash + upload run **here** (task isolate). Main only lists pending paths
/// and commits results — so work continues while the app is backgrounded.
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
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Without this, main waits forever on `_taskDone` and kick() never runs again.
    FlutterForegroundTask.sendDataToMain({
      'type': 'error',
      'message': isTimeout ? 'FG service timed out' : 'FG service stopped',
    });
  }

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
      final jobs = [
        for (final e in payload['jobs'] as List<dynamic>? ?? const [])
          IngestQueueItem.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
      final toHash = [
        for (final e in payload['pending'] as List<dynamic>? ?? const [])
          IngestQueueItem.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
      final needHashIds = {for (final i in toHash) i.id};
      final work = [...jobs, ...toHash];

      for (var i = 0; i < work.length; i++) {
        var item = work[i];
        try {
          if (needHashIds.contains(item.id)) {
            item = await _hashItem(item, index: i + 1, total: work.length);
          }
          final result = await _uploadOne(
            api: api,
            item: item,
            deviceId: deviceId,
            index: i + 1,
            total: work.length,
          );
          // CatalogFile.toJson copies tags to a plain List (isolate-safe).
          FlutterForegroundTask.sendDataToMain({
            'type': 'item_ok',
            'id': item.id,
            'file': result.file.toJson(),
            'availability': result.availability.toJson(),
          });
        } on KdbxConflictPendingException catch (e) {
          FlutterForegroundTask.sendDataToMain({
            'type': 'item_conflict',
            'id': item.id,
            'conflict_id': e.conflict.conflictId,
            'file_id': e.conflict.fileId,
            'state': e.conflict.state,
            'message': e.toString(),
          });
          // Keep going — other uploads may succeed.
        } catch (e) {
          FlutterForegroundTask.sendDataToMain({
            'type': 'item_err',
            'id': item.id,
            'message': e.toString(),
            'content_hash': item.contentHash,
            'size_bytes': item.sizeBytes,
            'source_path': item.sourcePath,
            'replace_file_id': item.replaceFileId,
            'title': item.title,
            'source_kind': item.sourceKind,
          });
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

  Future<IngestQueueItem> _hashItem(
    IngestQueueItem item, {
    required int index,
    required int total,
  }) async {
    final sourcePath = item.sourcePath;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw IngestException('missing source_path for hash ${item.id}');
    }
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw IngestException('file missing: $sourcePath');
    }
    final display = item.title ?? p.basename(sourcePath);

    // Main already verified mtime/size against a stored digest.
    if (item.contentHash.isNotEmpty) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'progress',
        'title': display,
        'index': index,
        'total': total,
        'phase': 'hashing',
        'fraction': 1.0,
      });
      return IngestQueueItem(
        id: item.id,
        contentHash: item.contentHash,
        hashAlgo: item.hashAlgo,
        sizeBytes: await file.length(),
        mimeType: item.mimeType,
        title: item.title,
        sourceKind: item.sourceKind,
        relativePath: item.relativePath,
        sourcePath: item.sourcePath,
        replaceFileId: item.replaceFileId,
        tags: item.tags,
        createdAt: item.createdAt,
      );
    }

    final hash = await ContentHash.blake3File(
      file,
      onProgress: (done, totalBytes) {
        final fraction = totalBytes == 0 ? 1.0 : done / totalBytes;
        FlutterForegroundTask.sendDataToMain({
          'type': 'progress',
          'title': display,
          'index': index,
          'total': total,
          'phase': 'hashing',
          'fraction': fraction,
        });
        unawaited(
          FlutterForegroundTask.updateService(
            notificationTitle: 'Homesync preparing',
            notificationText:
                'Hashing $index/$total: $display (${(fraction * 100).round()}%)',
          ),
        );
      },
    );
    final hashed = IngestQueueItem(
      id: item.id,
      contentHash: hash,
      hashAlgo: ContentHash.algo,
      sizeBytes: await file.length(),
      mimeType: item.mimeType,
      title: item.title,
      sourceKind: item.sourceKind,
      relativePath: item.relativePath,
      sourcePath: item.sourcePath,
      replaceFileId: item.replaceFileId,
      tags: item.tags,
      createdAt: item.createdAt,
    );
    // Persist digest before upload so a mid-transfer kill does not re-blake3.
    FlutterForegroundTask.sendDataToMain({
      'type': 'item_hashed',
      'id': hashed.id,
      'content_hash': hashed.contentHash,
      'size_bytes': hashed.sizeBytes,
      'source_path': hashed.sourcePath,
      'replace_file_id': hashed.replaceFileId,
      'title': hashed.title,
      'source_kind': hashed.sourceKind,
    });
    return hashed;
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

    FlutterForegroundTask.sendDataToMain({
      'type': 'progress',
      'title': display,
      'index': index,
      'total': total,
      'phase': 'uploading',
      'fraction': 0.0,
    });
    unawaited(
      FlutterForegroundTask.updateService(
        notificationTitle: 'Homesync uploading',
        notificationText: 'Uploading $index/$total: $display (0%)',
      ),
    );

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
        final fraction = totalBytes == 0 ? 1.0 : sent / totalBytes;
        FlutterForegroundTask.sendDataToMain({
          'type': 'progress',
          'title': display,
          'index': index,
          'total': total,
          'phase': 'uploading',
          'fraction': fraction,
        });
        unawaited(
          FlutterForegroundTask.updateService(
            notificationTitle: 'Homesync uploading',
            notificationText:
                'Uploading $index/$total: $display (${(fraction * 100).round()}%)',
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

    final created = item.replaceFileId != null
        ? await api.updateFileContent(
            item.replaceFileId!,
            FileContentRequest(
              contentHash: item.contentHash,
              hashAlgo: item.hashAlgo,
              sizeBytes: item.sizeBytes,
              note: 'phone track',
            ),
          )
        : await api.createFile(
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
      // Keep hash/upload alive after Home; we stopService when the batch ends.
      stopWithTask: false,
    ),
  );
}

/// Runs phone→PC ingest without blocking catalog refresh / UI.
///
/// On Android, hash + HTTP run in the `dataSync` task isolate. Main only lists
/// pending paths (Drift) and commits catalog rows when each item finishes.
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
  /// True after work was handed to the task isolate.
  bool _waitingOnTaskIsolate = false;
  IngestProgressCallback? _onProgress;
  Future<void> Function()? _onFinished;
  Map<String, IngestQueueItem> _jobsById = {};
  Future<void> _commitChain = Future<void>.value();
  DateTime? _lastNotificationUpdate;
  String? _lastNotificationText;

  bool get isRunning => _inFlight != null;

  /// Mirror prepare/hash/upload progress into the FG notification text.
  Future<void> updateKeepAliveProgress(IngestFileProgress p) async {
    if (!Platform.isAndroid) return;
    final text = switch (p.phase) {
      'scanning' => p.index > 0
          ? 'Scanning… ${p.title}'
          : 'Scanning device storage…',
      'preparing' => p.title,
      'hashing' => p.total > 0
          ? 'Hashing ${p.index}/${p.total}: ${p.title} (${(p.fraction * 100).round()}%)'
          : 'Hashing: ${p.title}',
      'uploading' => p.total > 0
          ? 'Uploading ${p.index}/${p.total}: ${p.title} (${(p.fraction * 100).round()}%)'
          : 'Uploading: ${p.title}',
      'finishing' => 'Finishing ${p.index}/${p.total}: ${p.title}',
      _ => '${p.phaseLabel} ${p.index}/${p.total}: ${p.title}',
    };
    final title = switch (p.phase) {
      'scanning' => 'Homesync scanning',
      'preparing' || 'hashing' => 'Homesync preparing',
      'uploading' => 'Homesync uploading',
      'finishing' => 'Homesync uploading',
      _ => 'Homesync syncing',
    };
    final now = DateTime.now();
    if (text == _lastNotificationText) return;
    final due = _lastNotificationUpdate == null ||
        now.difference(_lastNotificationUpdate!) >=
            const Duration(milliseconds: 400) ||
        p.phase == 'finishing' ||
        p.fraction >= 0.999 ||
        p.phase == 'scanning';
    if (!due) return;
    _lastNotificationUpdate = now;
    _lastNotificationText = text;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (e) {
      log.warn('ingest', 'notification update failed: $e');
    }
  }

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
      case 'item_hashed':
        _commitChain = _commitChain.then((_) => _commitItemHashed(map));
      case 'item_ok':
        _commitChain = _commitChain.then((_) => _commitItemOk(map));
      case 'item_conflict':
        log.warn(
          'ingest',
          'KeePass conflict ${map['conflict_id']} for job ${map['id']} '
          '(${map['state']}) — open KeePass conflicts (drawer or ⋮ menu)',
        );
      case 'item_err':
        log.warn(
          'ingest',
          'flush failed for ${map['id']}: ${map['message']}',
        );
        _commitChain = _commitChain.then((_) => _commitItemHashed(map));
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

  Future<void> _commitItemHashed(Map<String, dynamic> map) async {
    final path = map['source_path'] as String?;
    final hash = map['content_hash'] as String?;
    if (path == null || path.isEmpty || hash == null || hash.isEmpty) {
      // Prefer job payload when the task only sent an error id.
      final id = map['id'] as String?;
      final item = id == null ? null : _jobsById[id];
      if (item == null ||
          item.sourcePath == null ||
          item.contentHash.isEmpty) {
        return;
      }
      await _persistPendingDigest(
        localPath: item.sourcePath!,
        contentHash: item.contentHash,
        sizeBytes: item.sizeBytes,
        fileId: item.replaceFileId,
        title: item.title,
        sourceKind: item.sourceKind,
      );
      return;
    }
    await _persistPendingDigest(
      localPath: path,
      contentHash: hash,
      sizeBytes: map['size_bytes'] as int? ?? 0,
      fileId: map['replace_file_id'] as String?,
      title: map['title'] as String?,
      sourceKind: map['source_kind'] as String? ?? 'misc',
    );
  }

  Future<void> _persistPendingDigest({
    required String localPath,
    required String contentHash,
    required int sizeBytes,
    String? fileId,
    String? title,
    required String sourceKind,
  }) async {
    final existing = await scanner.repository.getLocalFile(localPath);
    final source = File(localPath);
    final mtimeMs = await source.exists()
        ? (await source.stat()).modified.millisecondsSinceEpoch
        : existing?.mtimeMs;
    await scanner.repository.upsertLocalFile(
      LocalTrackedFile(
        localPath: localPath,
        ruleId: existing?.ruleId,
        fileId: fileId ?? existing?.fileId,
        contentHash: contentHash,
        title: title ?? existing?.title,
        sizeBytes: sizeBytes > 0 ? sizeBytes : (existing?.sizeBytes ?? 0),
        mtimeMs: mtimeMs,
        mimeType: existing?.mimeType,
        sourceKind: existing?.sourceKind ?? sourceKind,
        seenAt: existing?.seenAt ?? DateTime.now().toUtc().toIso8601String(),
        ingestStatus: IngestStatus.pending,
      ),
    );
    // Keep in-memory job map in sync for a later item_ok/err.
    for (final entry in _jobsById.entries) {
      final job = entry.value;
      if (job.sourcePath == localPath) {
        _jobsById[entry.key] = IngestQueueItem(
          id: job.id,
          contentHash: contentHash,
          hashAlgo: job.hashAlgo,
          sizeBytes: sizeBytes > 0 ? sizeBytes : job.sizeBytes,
          mimeType: job.mimeType,
          title: job.title,
          sourceKind: job.sourceKind,
          relativePath: job.relativePath,
          sourcePath: job.sourcePath,
          replaceFileId: job.replaceFileId,
          tags: job.tags,
          createdAt: job.createdAt,
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
        final source = File(path);
        final stat = await source.exists() ? await source.stat() : null;
        await scanner.repository.markSynced(
          localPath: path,
          fileId: created.fileId,
          contentHash: created.contentHash,
          sizeBytes: created.sizeBytes,
          mtimeMs: stat?.modified.millisecondsSinceEpoch,
        );
      }
      log.info(
        'ingest',
        'ingested ${created.fileId} (${item.title ?? created.contentHash})',
      );
    } catch (e) {
      log.warn('ingest', 'commit after upload failed for $id: $e');
    }
  }

  /// Start the Android FG keep-alive while still in the foreground.
  Future<void> ensureKeepAlive() async {
    if (!Platform.isAndroid) return;
    await _requestNotificationPermission();
    await _requestBatteryOptimizationExemption();
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

  /// Call on app resume. If the FG service died mid-upload, unlock so [kick]
  /// can run again.
  Future<void> recoverAfterResume() async {
    final inflight = _inFlight;
    final done = _taskDone;
    if (inflight == null ||
        done == null ||
        done.isCompleted ||
        !_waitingOnTaskIsolate) {
      return;
    }
    if (await FlutterForegroundTask.isRunningService) return;

    log.warn('ingest', 'FG service stopped in background — unlocking stuck batch');
    done.complete();
    await inflight;
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

      void report(IngestFileProgress p) {
        onProgress?.call(p);
        unawaited(updateKeepAliveProgress(p));
      }
      report(
        const IngestFileProgress(
          title: 'Checking pending files…',
          index: 0,
          total: 0,
          phase: 'preparing',
          fraction: 0,
        ),
      );

      // Fast Drift/prefs read only — hashing happens in the task isolate.
      final queued = await ingest.queue.list();
      final pending = await _pendingHashJobs();
      if (queued.isEmpty && pending.isEmpty) {
        log.info('ingest', 'task-isolate: nothing to upload');
        if (!(_taskDone?.isCompleted ?? true)) {
          _taskDone!.complete();
        }
        return;
      }

      _jobsById = {
        for (final j in queued) j.id: j,
        for (final j in pending) j.id: j,
      };
      final deviceId = await identity.ensureDeviceId();
      final first = queued.isNotEmpty ? queued.first : pending.first;
      report(
        IngestFileProgress(
          title: first.title ?? first.sourcePath ?? 'upload',
          index: 1,
          total: queued.length + pending.length,
          phase: pending.isNotEmpty ? 'hashing' : 'uploading',
          fraction: 0,
        ),
      );

      _waitingOnTaskIsolate = true;
      FlutterForegroundTask.sendDataToTask({
        'type': 'run',
        'baseUrl': settings.baseUrl,
        'deviceId': deviceId,
        'jobs': queued.map((j) => j.toJson()).toList(),
        'pending': pending.map((j) => j.toJson()).toList(),
      });
      await _awaitTaskDone();
    } finally {
      _waitingOnTaskIsolate = false;
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

  /// Placeholder queue rows for files that still need hashing in the task isolate.
  Future<List<IngestQueueItem>> _pendingHashJobs() async {
    final rows = await scanner.listPendingNotQueued();
    if (rows.isEmpty) return const [];
    final rules =
        (await scanner.repository.listRules()).where((r) => r.enabled).toList();
    final byId = indexTrackingRules(rules);
    final now = DateTime.now().toUtc().toIso8601String();
    final out = <IngestQueueItem>[];
    for (final row in rows) {
      final source = File(row.localPath);
      final reuse = await source.exists() &&
          row.contentHash != null &&
          row.contentHash!.isNotEmpty &&
          row.mtimeMs != null &&
          (await source.stat()).size == row.sizeBytes &&
          (await source.stat()).modified.millisecondsSinceEpoch == row.mtimeMs;
      final meta = resolveTrackingIngestMeta(byId, row);
      out.add(
        IngestQueueItem(
          id: const Uuid().v4(),
          contentHash: reuse ? row.contentHash! : '',
          hashAlgo: ContentHash.algo,
          sizeBytes: row.sizeBytes,
          title: row.title,
          sourceKind: row.sourceKind,
          relativePath: meta.relativePath,
          sourcePath: row.localPath,
          replaceFileId: row.fileId,
          tags: meta.tags,
          createdAt: now,
        ),
      );
    }
    return out;
  }

  /// Wait for task-isolate `done`/`error`, or unlock if the FG service dies.
  Future<void> _awaitTaskDone() async {
    final done = _taskDone;
    if (done == null) return;
    while (!done.isCompleted) {
      await Future.any([
        done.future,
        Future<void>.delayed(const Duration(seconds: 3)),
      ]);
      if (done.isCompleted) return;
      if (!await FlutterForegroundTask.isRunningService) {
        log.warn('ingest', 'FG service gone during upload — ending batch');
        done.complete();
        return;
      }
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

  Future<void> _requestBatteryOptimizationExemption() async {
    try {
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return;
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (e) {
      log.warn('ingest', 'battery optimization request failed: $e');
    }
  }
}
