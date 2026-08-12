import 'dart:convert';
import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/local_thumb_store.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/background_ingest_runner.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/deletion_outbox.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_repository.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/thumb_service.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/device_scanner.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sampleFile = CatalogFile(
  fileId: 'f1',
  contentHash: 'abc0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab',
  hashAlgo: 'blake3',
  mimeType: 'text/plain',
  sizeBytes: 12,
  title: 'hello.txt',
  createdAt: '2026-07-31T00:00:00Z',
  updatedAt: '2026-07-31T00:00:00.000000Z',
  tags: ['family'],
);

String catalogFileJson({
  required String id,
  required String title,
  required String updatedAt,
  String? deletedAt,
  List<String> tags = const [],
  String? contentHash,
  int sizeBytes = 12,
  String mimeType = 'text/plain',
  bool hasThumb = false,
}) {
  final tagJson = tags.map((t) => '"$t"').join(',');
  final hash = contentHash ?? 'hash-$id-pad-to-make-length-ok-abcdefghijklmnop';
  return '''
{
  "file_id": "$id",
  "content_hash": "$hash",
  "hash_algo": "blake3",
  "mime_type": "$mimeType",
  "size_bytes": $sizeBytes,
  "title": "$title",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-07-31T00:00:00Z",
  "updated_at": "$updatedAt",
  "deleted_at": ${deletedAt == null ? 'null' : '"$deletedAt"'},
  "tags": [$tagJson],
  "has_thumb": $hasThumb
}
''';
}

String catalogPathJson({
  required String id,
  required String fileId,
  String sourceKind = 'whatsapp',
  String relativePath = 'ingest/whatsapp/photo.jpg',
  String? sourceDeviceId = 'd1',
  bool isCurrent = true,
}) {
  return '''
{
  "id": "$id",
  "file_id": "$fileId",
  "root_id": null,
  "relative_path": "$relativePath",
  "source_kind": "$sourceKind",
  "source_device_id": ${sourceDeviceId == null ? 'null' : '"$sourceDeviceId"'},
  "is_current": $isCurrent,
  "seen_at": "2026-07-31T00:00:00Z",
  "gone_at": null
}
''';
}

http.Response deviceOkResponse() => http.Response(
      '{"device_id":"d1","name":"android","kind":"android",'
      '"created_at":"2026-07-31T00:00:00Z","last_seen_at":"2026-07-31T00:00:00Z"}',
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response availabilityOkResponse({
  required String fileId,
  required String mode,
  String deviceId = 'd1',
  String updatedAt = '2026-07-31T01:00:00Z',
}) =>
    http.Response(
      '{"file_id":"$fileId","device_id":"$deviceId","mode":"$mode",'
      '"updated_at":"$updatedAt"}',
      200,
      headers: {'content-type': 'application/json'},
    );

/// Mock handler for resumable `POST/PATCH/GET /v1/blob-uploads…`.
/// Returns null when [request] is not a blob-upload call.
http.Response? mockBlobUploadResponse(
  http.Request request, {
  int Function()? patchStatus,
}) {
  final path = request.url.path;
  if (request.method == 'POST' && path.endsWith('/blob-uploads')) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final algo = body['algo'] as String? ?? 'blake3';
    final hash = body['content_hash'] as String;
    final size = body['size_bytes'] as int;
    return http.Response(
      jsonEncode({
        'upload_id': '$algo:$hash',
        'algo': algo,
        'content_hash': hash,
        'size_bytes': size,
        'offset': 0,
        'complete': false,
        'last_activity': '2026-08-03T00:00:00Z',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path.contains('/blob-uploads/')) {
    final id = path.split('/blob-uploads/').last;
    final parts = id.split(':');
    return http.Response(
      jsonEncode({
        'upload_id': id,
        'algo': parts.first,
        'content_hash': parts.length > 1 ? parts.sublist(1).join(':') : '',
        'size_bytes': 0,
        'offset': 0,
        'complete': false,
        'last_activity': '2026-08-03T00:00:00Z',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'PATCH' && path.contains('/blob-uploads/')) {
    final status = patchStatus?.call() ?? 204;
    if (status != 204 && status != 200) {
      return http.Response('fail', status);
    }
    final offset = int.parse(request.headers['upload-offset'] ?? '0');
    final newOffset = offset + request.bodyBytes.length;
    return http.Response(
      '',
      204,
      headers: {
        'upload-offset': '$newOffset',
        'upload-length': '$newOffset',
        'x-upload-complete': '1',
      },
    );
  }
  return null;
}

class TestCatalogHarness {
  TestCatalogHarness({
    required this.log,
    required this.settings,
    required this.database,
    required this.repository,
    required this.api,
    required this.sync,
    required this.identity,
    required this.blobs,
    required this.thumbs,
    required this.pinService,
    required this.thumbService,
    required this.ingestQueue,
    required this.deletionOutbox,
    required this.folderPinSubscriptions,
    required this.folderPins,
    required this.ingestService,
    required this.tracking,
    required this.scanner,
    required this.backgroundIngest,
    required this.blobRoot,
    required this.thumbRoot,
    required this.scanRoot,
  });

  final AppLog log;
  final SettingsStore settings;
  final CatalogDatabase database;
  final CatalogRepository repository;
  final HomesyncApi api;
  final CatalogSync sync;
  final DeviceIdentity identity;
  final LocalBlobStore blobs;
  final LocalThumbStore thumbs;
  final PinService pinService;
  final ThumbService thumbService;
  final IngestQueue ingestQueue;
  final DeletionOutbox deletionOutbox;
  final FolderPinRepository folderPinSubscriptions;
  final FolderPinService folderPins;
  final IngestService ingestService;
  final TrackingRepository tracking;
  final DeviceScanner scanner;
  final BackgroundIngestRunner backgroundIngest;
  final Directory blobRoot;
  final Directory thumbRoot;
  final Directory scanRoot;

  CatalogCubit makeCubit() => CatalogCubit(
        repository: repository,
        sync: sync,
        api: api,
        pinService: pinService,
        thumbService: thumbService,
        tracking: tracking,
        scanner: scanner,
        backgroundIngest: backgroundIngest,
        deletionOutbox: deletionOutbox,
        folderPins: folderPins,
        folderPinSubscriptions: folderPinSubscriptions,
        settings: settings,
        log: log,
      );

  static Future<TestCatalogHarness> open(
    MockClient client, {
    Directory? blobRoot,
    Directory? thumbRoot,
    Directory? scanRoot,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final log = AppLog.silent();
    final settings = await SettingsStore.open(log);
    await settings.setDeviceId('d1');
    final database = CatalogDatabase.memory();
    final root = blobRoot ??
        Directory.systemTemp.createTempSync('homesync_pins_test_');
    final tRoot = thumbRoot ??
        Directory.systemTemp.createTempSync('homesync_thumbs_test_');
    final scan = scanRoot ??
        Directory.systemTemp.createTempSync('homesync_scan_test_');
    final blobs = LocalBlobStore.forRoot(log, root);
    final thumbs = LocalThumbStore.forRoot(log, tRoot);
    final identity = DeviceIdentity(settings, log);
    final repository = CatalogRepository(database, log, blobs, identity);
    final api = HomesyncApi.withClient(settings, log, client);
    final ingestQueue = IngestQueue(settings, log);
    final deletionOutbox = DeletionOutbox(settings, log);
    final folderPinSubscriptions = FolderPinRepository(database, log);
    final ingestService = IngestService(
      api: api,
      repository: repository,
      blobs: blobs,
      identity: identity,
      queue: ingestQueue,
      log: log,
    );
    final sync = CatalogSync(
      api: api,
      repository: repository,
      identity: identity,
      settings: settings,
      ingest: ingestService,
      log: log,
    );
    final pinService = PinService(
      api: api,
      repository: repository,
      blobs: blobs,
      identity: identity,
      settings: settings,
      log: log,
    );
    final folderPins = FolderPinService(
      subscriptions: folderPinSubscriptions,
      repository: repository,
      pinService: pinService,
      log: log,
    );
    final thumbService = ThumbService(api: api, thumbs: thumbs, log: log);
    final tracking = TrackingRepository(database, log);
    final scanner = DeviceScanner(
      repository: tracking,
      ingest: ingestService,
      log: log,
      scanRoots: [scan],
    );
    final backgroundIngest = BackgroundIngestRunner(
      scanner: scanner,
      ingest: ingestService,
      settings: settings,
      identity: identity,
      log: log,
    );
    return TestCatalogHarness(
      log: log,
      settings: settings,
      database: database,
      repository: repository,
      api: api,
      sync: sync,
      identity: identity,
      blobs: blobs,
      thumbs: thumbs,
      pinService: pinService,
      thumbService: thumbService,
      ingestQueue: ingestQueue,
      deletionOutbox: deletionOutbox,
      folderPinSubscriptions: folderPinSubscriptions,
      folderPins: folderPins,
      ingestService: ingestService,
      tracking: tracking,
      scanner: scanner,
      backgroundIngest: backgroundIngest,
      blobRoot: root,
      thumbRoot: tRoot,
      scanRoot: scan,
    );
  }

  Future<void> close() async {
    await repository.close();
    if (await blobRoot.exists()) {
      await blobRoot.delete(recursive: true);
    }
    if (await thumbRoot.exists()) {
      await thumbRoot.delete(recursive: true);
    }
    if (await scanRoot.exists()) {
      await scanRoot.delete(recursive: true);
    }
  }
}
