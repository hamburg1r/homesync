/// Milestone 5 client exit check: phone ingest uploads blob + creates file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
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

  test('ingest puts blob, creates file, pins phone; queue flushes on retry',
      () async {
    final payload = Uint8List.fromList(utf8.encode('camera photo from phone\n'));
    final hash = ContentHash.blake3Hex(payload);
    var putCount = 0;
    var createCount = 0;
    var failPutOnce = true;

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
  "next_cursor": "",
  "files": [],
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
        if (request.method == 'PUT' && request.url.path.contains('/blobs/')) {
          putCount += 1;
          if (failPutOnce) {
            failPutOnce = false;
            return http.Response('offline', 503);
          }
          expect(request.url.path, contains(hash));
          expect(request.bodyBytes, payload);
          return http.Response(
            '',
            201,
            headers: {
              'x-content-hash': hash,
              'x-hash-algo': 'blake3',
              'x-blob-created': '1',
            },
          );
        }
        if (request.method == 'POST' && request.url.path.endsWith('/files')) {
          createCount += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['content_hash'], hash);
          expect(body['source_kind'], 'camera');
          expect(body['source_device_id'], 'd1');
          return http.Response(
            '''
{
  "file_id": "ingested-1",
  "content_hash": "$hash",
  "hash_algo": "blake3",
  "mime_type": "image/jpeg",
  "size_bytes": ${payload.length},
  "title": "IMG_001.jpg",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-08-02T00:00:00Z",
  "updated_at": "2026-08-02T00:00:00.000000Z",
  "deleted_at": null,
  "tags": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.contains('/availability/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return availabilityOkResponse(
            fileId: 'ingested-1',
            mode: body['mode'] as String,
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    // First attempt queues after network failure.
    await expectLater(
      harness.ingestService.ingestBytes(
        payload,
        title: 'IMG_001.jpg',
        mimeType: 'image/jpeg',
      ),
      throwsA(isA<Exception>()),
    );
    expect(await harness.blobs.has('blake3', hash), isTrue);
    expect(await harness.ingestQueue.list(), hasLength(1));
    expect(putCount, 1);
    expect(createCount, 0);

    // Reconnect sync flushes the durable queue.
    final result = await harness.sync.sync();
    expect(result.ok, isTrue);
    expect(result.ingestsFlushed, 1);
    expect(putCount, 2);
    expect(createCount, 1);
    expect(await harness.ingestQueue.list(), isEmpty);

    final files = await harness.repository.listActiveFiles();
    expect(files.map((f) => f.fileId), ['ingested-1']);
    expect(files.first.availabilityMode, AvailabilityMode.pinned);
    expect(files.first.hasLocalBytes, isTrue);
    expect(files.first.title, 'IMG_001.jpg');
  });
}
