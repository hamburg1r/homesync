/// GC leftover cleanup: delta `purged[]` + local Forget for Removed from PC.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('delta purged[] hard-deletes local tombstone leftover', () async {
    var page = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          page += 1;
          if (page == 1) {
            return http.Response(
              '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'gone.txt', updatedAt: 'a', deletedAt: 'a')}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [],
  "next_purge_cursor": ""
}
''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [{"file_id": "f1", "purged_at": "2026-08-03T12:00:00.000000Z"}],
  "next_purge_cursor": "2026-08-03T12:00:00.000000Z"
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.listTombstonedFiles(), hasLength(1));

    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.listTombstonedFiles(), isEmpty);
    expect(await harness.repository.getFile('f1'), isNull);
    expect(
      await harness.repository.getPurgeCursor(),
      '2026-08-03T12:00:00.000000Z',
    );
  });

  test('purge keeps unbound local bytes', () async {
    const hash =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    const payload = 'keep me unbound\n';
    var page = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          page += 1;
          if (page == 1) {
            return http.Response(
              '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'pin.txt', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [],
  "next_purge_cursor": ""
}
''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [{"file_id": "f1", "purged_at": "2026-08-03T12:00:00.000000Z"}],
  "next_purge_cursor": "2026-08-03T12:00:00.000000Z"
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    await harness.blobs.write(
      'blake3',
      hash,
      Uint8List.fromList(payload.codeUnits),
    );
    expect(await harness.blobs.has('blake3', hash), isTrue);

    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.getFile('f1'), isNull);
    expect(await harness.blobs.has('blake3', hash), isTrue);
  });

  test('purge deletes local bytes when bound to server', () async {
    const hash =
        'bbccddeeff00112233445566778899aabbccddeeff00112233445566778899aa';
    const payload = 'bound delete me\n';
    var page = 0;
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          page += 1;
          if (page == 1) {
            return http.Response(
              '''
{
  "next_cursor": "v1:a|f2",
  "files": [${catalogFileJson(id: 'f2', title: 'bound.txt', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [],
  "next_purge_cursor": ""
}
''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f2",
  "files": [],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [{"file_id": "f2", "purged_at": "2026-08-03T13:00:00.000000Z"}],
  "next_purge_cursor": "2026-08-03T13:00:00.000000Z"
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    await harness.blobs.write(
      'blake3',
      hash,
      Uint8List.fromList(payload.codeUnits),
    );
    await harness.repository.setBoundToServer('f2', bound: true);
    expect(await harness.blobs.has('blake3', hash), isTrue);

    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.getFile('f2'), isNull);
    expect(await harness.blobs.has('blake3', hash), isFalse);
  });

  test('forgetLocalFile and forgetAllTombstones clear Removed list', () async {
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '''
{
  "next_cursor": "v1:b|f2",
  "files": [
    ${catalogFileJson(id: 'f1', title: 'a.txt', updatedAt: 'a', deletedAt: 'a')},
    ${catalogFileJson(id: 'f2', title: 'b.txt', updatedAt: 'b', deletedAt: 'b')}
  ],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [],
  "purged": [],
  "next_purge_cursor": ""
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    expect(await harness.repository.listTombstonedFiles(), hasLength(2));

    await harness.repository.forgetLocalFile('f1');
    expect(await harness.repository.getFile('f1'), isNull);
    expect(await harness.repository.listTombstonedFiles(), hasLength(1));

    final n = await harness.repository.forgetAllTombstones();
    expect(n, 1);
    expect(await harness.repository.listTombstonedFiles(), isEmpty);
  });

  test('CatalogDelta parses purged fields', () {
    final delta = CatalogDelta.fromJson({
      'next_cursor': 'v1:x|y',
      'files': [],
      'tags': [],
      'file_tags': [],
      'paths': [],
      'availability': [],
      'purged': [
        {'file_id': 'f9', 'purged_at': 't'},
      ],
      'next_purge_cursor': 't',
    });
    expect(delta.purged, hasLength(1));
    expect(delta.purged.first.fileId, 'f9');
    expect(delta.nextPurgeCursor, 't');
  });
}
