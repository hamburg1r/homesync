import 'dart:io';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_blob_store.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_queue.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
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
}) {
  final tagJson = tags.map((t) => '"$t"').join(',');
  final hash = contentHash ?? 'hash-$id-pad-to-make-length-ok-abcdefghijklmnop';
  return '''
{
  "file_id": "$id",
  "content_hash": "$hash",
  "hash_algo": "blake3",
  "mime_type": "text/plain",
  "size_bytes": $sizeBytes,
  "title": "$title",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-07-31T00:00:00Z",
  "updated_at": "$updatedAt",
  "deleted_at": ${deletedAt == null ? 'null' : '"$deletedAt"'},
  "tags": [$tagJson]
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

class TestCatalogHarness {
  TestCatalogHarness({
    required this.log,
    required this.settings,
    required this.database,
    required this.repository,
    required this.api,
    required this.sync,
    required this.blobs,
    required this.pinService,
    required this.ingestQueue,
    required this.ingestService,
    required this.blobRoot,
  });

  final AppLog log;
  final SettingsStore settings;
  final CatalogDatabase database;
  final CatalogRepository repository;
  final HomesyncApi api;
  final CatalogSync sync;
  final LocalBlobStore blobs;
  final PinService pinService;
  final IngestQueue ingestQueue;
  final IngestService ingestService;
  final Directory blobRoot;

  static Future<TestCatalogHarness> open(
    MockClient client, {
    Directory? blobRoot,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final log = AppLog.silent();
    final settings = await SettingsStore.open(log);
    // Stable device id for availability rows in tests.
    await settings.setDeviceId('d1');
    final database = CatalogDatabase.memory();
    final root = blobRoot ??
        Directory.systemTemp.createTempSync('homesync_pins_test_');
    final blobs = LocalBlobStore.forRoot(log, root);
    final identity = DeviceIdentity(settings, log);
    final repository = CatalogRepository(database, log, blobs, identity);
    final api = HomesyncApi.withClient(settings, log, client);
    final ingestQueue = IngestQueue(settings, log);
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
    return TestCatalogHarness(
      log: log,
      settings: settings,
      database: database,
      repository: repository,
      api: api,
      sync: sync,
      blobs: blobs,
      pinService: pinService,
      ingestQueue: ingestQueue,
      ingestService: ingestService,
      blobRoot: root,
    );
  }

  Future<void> close() async {
    await repository.close();
    if (await blobRoot.exists()) {
      await blobRoot.delete(recursive: true);
    }
  }
}
