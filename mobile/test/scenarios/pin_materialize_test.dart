/// Milestone 4 client exit check: pin materializes bytes; unpin keeps listing.
///
/// Airplane-mode device E2E is Later; this covers the phone-free pin contract.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/pin_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('pin downloads bytes; listed-only has no local bytes; unpin deletes bytes',
      () async {
    const payload = 'hello pin\n';
    final hash =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

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
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'hello.txt', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
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
        if (request.method == 'PUT' &&
            request.url.path.contains('/availability/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return availabilityOkResponse(
            fileId: 'f1',
            mode: body['mode'] as String,
          );
        }
        if (request.method == 'GET' && request.url.path.contains('/blobs/')) {
          return http.Response(
            payload,
            200,
            headers: {
              'content-type': 'application/octet-stream',
              'content-length': '${payload.length}',
            },
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    final listed = await harness.repository.listActiveFiles();
    expect(listed, hasLength(1));
    expect(listed.first.availabilityMode, AvailabilityMode.listed);
    expect(listed.first.hasLocalBytes, isFalse);

    // Listed-only cannot open.
    expect(await harness.pinService.openLocalBytes(listed.first), isNull);

    final pinned = await harness.pinService.pin('f1');
    expect(pinned.availabilityMode, AvailabilityMode.pinned);
    expect(pinned.hasLocalBytes, isTrue);
    expect(await harness.blobs.has('blake3', hash), isTrue);

    final bytes = await harness.pinService.openLocalBytes(pinned);
    expect(bytes, isNotNull);
    expect(utf8.decode(bytes!), payload);

    final unpinned = await harness.pinService.unpin('f1');
    expect(unpinned.availabilityMode, AvailabilityMode.listed);
    expect(unpinned.hasLocalBytes, isFalse);
    expect(await harness.blobs.has('blake3', hash), isFalse);

    // Listing survives unpin.
    final stillListed = await harness.repository.listActiveFiles();
    expect(stillListed.map((f) => f.fileId), ['f1']);
    expect(await harness.pinService.openLocalBytes(stillListed.first), isNull);
  });

  test('missing blob on PC rolls availability back and surfaces error', () async {
    final hash =
        '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'ghost.txt', updatedAt: 'a', contentHash: hash)}],
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
        if (request.method == 'PUT' &&
            request.url.path.contains('/availability/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return availabilityOkResponse(
            fileId: 'f1',
            mode: body['mode'] as String,
          );
        }
        if (request.method == 'GET' && request.url.path.contains('/blobs/')) {
          return http.Response('{"detail":"blob not found"}', 404);
        }
        return http.Response('unexpected', 500);
      }),
    );

    await harness.sync.sync();
    await expectLater(
      harness.pinService.pin('f1'),
      throwsA(
        isA<PinException>().having(
          (e) => e.message,
          'message',
          contains('blob missing on PC'),
        ),
      ),
    );
    final files = await harness.repository.listActiveFiles();
    expect(files.first.availabilityMode, AvailabilityMode.listed);
    expect(files.first.hasLocalBytes, isFalse);
  });

  test('disk budget rejects pin when over limit', () async {
    final hash =
        '99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa';

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'big.txt', updatedAt: 'a', contentHash: hash, sizeBytes: 1000)}],
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
        return http.Response('should not reach', 500);
      }),
    );

    await harness.sync.sync();
    await harness.settings.setPinBudgetBytes(100);

    await expectLater(
      harness.pinService.pin('f1'),
      throwsA(
        isA<PinException>().having(
          (e) => e.message,
          'message',
          contains('disk budget'),
        ),
      ),
    );
  });

  test('delta availability from server overrides default listed', () async {
    final hash =
        'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
        return http.Response(
          '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'pre-pinned.txt', updatedAt: 'a', contentHash: hash)}],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [
    {"file_id":"f1","device_id":"d1","mode":"pinned","updated_at":"a"}
  ]
}
''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await harness.sync.sync();
    final files = await harness.repository.listActiveFiles();
    expect(files.first.availabilityMode, AvailabilityMode.pinned);
    // Bytes still absent until materialize download.
    expect(files.first.hasLocalBytes, isFalse);
  });

  test('pin to custom path; keepOnPcOnly deletes local file', () async {
    const payload = 'custom dest\n';
    final hash =
        'ccddeeff00112233445566778899aabbccddeeff00112233445566778899aabb';
    final destRoot = Directory.systemTemp.createTempSync('homesync_pin_dest_');

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
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'photo.jpg', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
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
        if (request.method == 'PUT' &&
            request.url.path.contains('/availability/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return availabilityOkResponse(
            fileId: 'f1',
            mode: body['mode'] as String,
          );
        }
        if (request.method == 'GET' && request.url.path.contains('/blobs/')) {
          return http.Response(payload, 200);
        }
        return http.Response('unexpected', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    final pinned = await harness.pinService.pin(
      'f1',
      destination: PinDestination(
        directory: destRoot.path,
        fileName: 'photo.jpg',
      ),
    );
    expect(pinned.hasLocalBytes, isTrue);
    expect(await harness.blobs.has('blake3', hash), isFalse);
    final path = await harness.repository.pinLocalPathForFileId('f1');
    expect(path, endsWith('photo.jpg'));
    expect(File(path!).existsSync(), isTrue);

    final kept = await harness.pinService.keepOnPcOnly('f1');
    expect(kept.availabilityMode, AvailabilityMode.listed);
    expect(kept.hasLocalBytes, isFalse);
    expect(File(path).existsSync(), isFalse);
    expect(await harness.repository.pinLocalPathForFileId('f1'), isNull);

    await destRoot.delete(recursive: true);
  });
}
