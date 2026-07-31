import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/api/homesync_api.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_database.dart';
import 'package:homesync_mobile/features/catalog/data/local_db/catalog_repository.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/catalog_sync.dart';
import 'package:homesync_mobile/features/catalog/data/sync/device_identity.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sampleFile = CatalogFile(
  fileId: 'f1',
  contentHash: 'abc',
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
}) {
  final tagJson = tags.map((t) => '"$t"').join(',');
  return '''
{
  "file_id": "$id",
  "content_hash": "hash-$id",
  "hash_algo": "blake3",
  "mime_type": "text/plain",
  "size_bytes": 12,
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

class TestCatalogHarness {
  TestCatalogHarness({
    required this.log,
    required this.settings,
    required this.database,
    required this.repository,
    required this.api,
    required this.sync,
  });

  final AppLog log;
  final SettingsStore settings;
  final CatalogDatabase database;
  final CatalogRepository repository;
  final HomesyncApi api;
  final CatalogSync sync;

  static Future<TestCatalogHarness> open(MockClient client) async {
    SharedPreferences.setMockInitialValues({});
    final log = AppLog.silent();
    final settings = await SettingsStore.open(log);
    final database = CatalogDatabase.memory();
    final repository = CatalogRepository(database, log);
    final api = HomesyncApi.withClient(settings, log, client);
    final sync = CatalogSync(
      api: api,
      repository: repository,
      identity: DeviceIdentity(settings, log),
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
    );
  }

  Future<void> close() => repository.close();
}
