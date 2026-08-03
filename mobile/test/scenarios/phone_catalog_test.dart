/// Milestone 3 client exit check: device hello + delta sync into Drift mirror.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('multi-page delta applies both pages and advances cursor', () async {
    var deltaCalls = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        deltaCalls += 1;
        if (deltaCalls == 1) {
          return http.Response(
            '''
{
  "next_cursor": "v1:2026-07-31T00:00:00.000001Z|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'one.txt', updatedAt: '2026-07-31T00:00:00.000001Z')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (deltaCalls == 2) {
          return http.Response(
            '''
{
  "next_cursor": "v1:2026-07-31T00:00:00.000002Z|f2",
  "files": [${catalogFileJson(id: 'f2', title: 'two.txt', updatedAt: '2026-07-31T00:00:00.000002Z')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"next_cursor":"v1:2026-07-31T00:00:00.000002Z|f2","files":[],'
          '"tags":[],"file_tags":[],"paths":[],"availability":[]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await harness.sync.sync(pageLimit: 1);
    expect(result.ok, isTrue);
    expect(result.filesTouched, 2);
    final listed = await harness.repository.listActiveFiles();
    expect(listed.map((f) => f.fileId).toSet(), {'f1', 'f2'});
    expect(
      await harness.repository.getDeltaCursor(),
      'v1:2026-07-31T00:00:00.000002Z|f2',
    );
  });

  test('tombstone removes file from active list', () async {
    var step = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        step += 1;
        if (step == 1) {
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'alive.txt', updatedAt: 'a', tags: ['family'])}],
  "tags": [{"tag_id": "t1", "name": "family", "color": null}],
  "file_tags": [{"file_id": "f1", "tag_id": "t1"}],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '''
{
  "next_cursor": "v1:b|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'alive.txt', updatedAt: 'b', deletedAt: 'b')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await harness.sync.sync();
    expect(await harness.repository.listActiveFiles(), hasLength(1));
    await harness.sync.sync();
    expect(await harness.repository.listActiveFiles(), isEmpty);
    expect(await harness.repository.getDeltaCursor(), 'v1:b|f1');
  });

  test('mid-sync failure keeps last successfully applied cursor', () async {
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        return http.Response(
          '''
{
  "next_cursor": "v1:good|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'ok.txt', updatedAt: 'good')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.getDeltaCursor(), 'v1:good|f1');

    // Re-open harness with failing second page; seed f1 into fresh memory DB.
    await harness.close();
    var step = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        step += 1;
        if (step == 1) {
          return http.Response(
            '''
{
  "next_cursor": "v1:mid|f2",
  "files": [${catalogFileJson(id: 'f2', title: 'mid.txt', updatedAt: 'mid')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('boom', 503);
      }),
    );
    await harness.repository.applyDelta(
      CatalogDelta(
        nextCursor: 'v1:good|f1',
        files: [
          CatalogFile(
            fileId: 'f1',
            contentHash: 'hash-f1',
            hashAlgo: 'blake3',
            sizeBytes: 12,
            title: 'ok.txt',
            createdAt: '2026-07-31T00:00:00Z',
            updatedAt: 'good',
          ),
        ],
      ),
    );

    final failed = await harness.sync.sync(pageLimit: 1);
    expect(failed.ok, isFalse);
    expect(await harness.repository.getDeltaCursor(), 'v1:mid|f2');
    expect(
      (await harness.repository.listActiveFiles()).map((f) => f.fileId).toSet(),
      {'f1', 'f2'},
    );
  });

  test('validateBaseUrl rejects bad schemes and empty', () {
    expect(SettingsStore.validateBaseUrl(''), isNotNull);
    expect(SettingsStore.validateBaseUrl('ftp://x'), isNotNull);
    expect(SettingsStore.validateBaseUrl('not-a-url'), isNotNull);
    expect(SettingsStore.validateBaseUrl('http://10.0.2.2:8787'), isNull);
  });

  test('listActiveFiles tolerates multiple origin paths for one file_id',
      () async {
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        return http.Response(
          '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'dup.txt', updatedAt: 'a')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": []
}
''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);

    final a = File('${harness.scanRoot.path}/a/dup.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('copy-a');
    final b = File('${harness.scanRoot.path}/b/dup.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('copy-b');

    await harness.tracking.upsertLocalFile(
      LocalTrackedFile(
        localPath: a.path,
        fileId: 'f1',
        contentHash: 'hash-f1',
        title: 'dup.txt',
        sizeBytes: 6,
        sourceKind: 'download',
        seenAt: '2026-08-01T00:00:00Z',
        ingestStatus: IngestStatus.synced,
      ),
    );
    await harness.tracking.upsertLocalFile(
      LocalTrackedFile(
        localPath: b.path,
        fileId: 'f1',
        contentHash: 'hash-f1',
        title: 'dup.txt',
        sizeBytes: 6,
        sourceKind: 'download',
        seenAt: '2026-08-02T00:00:00Z',
        ingestStatus: IngestStatus.synced,
      ),
    );

    // Regression: getSingleOrNull threw "Too many elements" and emptied home.
    final listed = await harness.repository.listActiveFiles();
    expect(listed, hasLength(1));
    expect(listed.single.fileId, 'f1');
    expect(listed.single.hasLocalBytes, isTrue);

    final origins = await harness.repository.originPathsForFileId('f1');
    expect(origins.toSet(), {a.path, b.path});
    expect(await harness.repository.originPathForFileId('f1'), isNotNull);
  });
}
