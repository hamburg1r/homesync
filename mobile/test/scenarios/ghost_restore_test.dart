/// Milestone 6 client exit check: ghost listing + bring-to-phone restore.
///
/// Delete local bytes (unpin) → still listed with provenance → restore via pin.
/// PC soft-delete tombstone drops active listing (still under Removed from PC).
library;

import 'dart:convert';

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

  test('ghost: unpin keeps listing; bring-to-phone restores bytes + provenance',
      () async {
    const payload = 'whatsapp ghost bytes\n';
    final hash =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    var pinMode = 'listed';

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
  "files": [${catalogFileJson(id: 'f1', title: 'IMG-WA0001.jpg', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
  "tags": [],
  "file_tags": [],
  "paths": [${catalogPathJson(id: 'p1', fileId: 'f1', sourceKind: 'whatsapp')}],
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
          pinMode = body['mode'] as String;
          return availabilityOkResponse(fileId: 'f1', mode: pinMode);
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
    var listed = await harness.repository.listActiveFiles();
    expect(listed, hasLength(1));
    expect(listed.first.primarySourceKind, 'whatsapp');
    expect(listed.first.isGhost, isTrue);
    expect(listed.first.provenanceSubtitle, 'from WhatsApp · on PC only');
    expect(listed.first.hasLocalBytes, isFalse);

    // Bring to phone (= pin + download).
    final restored = await harness.pinService.bringToPhone('f1');
    expect(restored.availabilityMode, AvailabilityMode.pinned);
    expect(restored.hasLocalBytes, isTrue);
    expect(restored.isGhost, isFalse);
    expect(restored.provenanceSubtitle, 'from WhatsApp · on device');
    expect(utf8.decode((await harness.pinService.openLocalBytes(restored))!),
        payload);

    // Delete local copy — listing + provenance remain (ghost again).
    final unpinned = await harness.pinService.unpin('f1');
    expect(unpinned.availabilityMode, AvailabilityMode.listed);
    expect(unpinned.hasLocalBytes, isFalse);
    expect(unpinned.isGhost, isTrue);
    listed = await harness.repository.listActiveFiles();
    expect(listed.map((f) => f.fileId), ['f1']);
    expect(listed.first.provenanceSubtitle, 'from WhatsApp · on PC only');

    // Restore again from PC.
    final again = await harness.pinService.bringToPhone('f1');
    expect(again.hasLocalBytes, isTrue);
    expect(await harness.blobs.has('blake3', hash), isTrue);
  });

  test('tombstone removes listing; keeps local bytes unless bound to server',
      () async {
    const payload = 'soon deleted\n';
    final hash =
        '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';
    var step = 0;

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
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
        step += 1;
        if (step == 1) {
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'keep.txt', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
  "tags": [],
  "file_tags": [],
  "paths": [${catalogPathJson(id: 'p1', fileId: 'f1', sourceKind: 'camera')}],
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
  "files": [${catalogFileJson(id: 'f1', title: 'keep.txt', updatedAt: 'b', deletedAt: 'b', contentHash: hash, sizeBytes: payload.length)}],
  "tags": [],
  "file_tags": [],
  "paths": [${catalogPathJson(id: 'p1', fileId: 'f1', sourceKind: 'camera')}],
  "availability": []
}
''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await harness.sync.sync();
    await harness.pinService.pin('f1');
    expect(await harness.blobs.has('blake3', hash), isTrue);
    expect(await harness.repository.listActiveFiles(), hasLength(1));

    // Default: unbound — tombstone drops active listing but keeps pin bytes.
    await harness.sync.sync();
    expect(await harness.repository.listActiveFiles(), isEmpty);
    expect(await harness.blobs.has('blake3', hash), isTrue);
    final removed = await harness.repository.listTombstonedFiles();
    expect(removed, hasLength(1));
    expect(removed.first.fileId, 'f1');
    expect(removed.first.isDeleted, isTrue);
    expect(removed.first.hasLocalBytes, isTrue);
    expect(removed.first.availabilityMode, AvailabilityMode.listed);
    expect(
      removed.first.provenanceSubtitle,
      contains('removed from PC'),
    );

    await harness.repository.discardLocalBytes(removed.first);
    final after = await harness.repository.listTombstonedFiles();
    expect(after, hasLength(1));
    expect(after.first.hasLocalBytes, isFalse);
    expect(await harness.blobs.has('blake3', hash), isFalse);
  });

  test('bound to server: tombstone deletes local pin bytes', () async {
    const payload = 'bound delete\n';
    final hash =
        '99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa';
    var step = 0;

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST') return deviceOkResponse();
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
        step += 1;
        if (step == 1) {
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'bound.txt', updatedAt: 'a', contentHash: hash, sizeBytes: payload.length)}],
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
          '''
{
  "next_cursor": "v1:b|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'bound.txt', updatedAt: 'b', deletedAt: 'b', contentHash: hash, sizeBytes: payload.length)}],
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
    await harness.pinService.pin('f1');
    await harness.repository.setBoundToServer('f1', bound: true);
    expect((await harness.repository.getFile('f1'))!.boundToServer, isTrue);

    await harness.sync.sync();
    expect(await harness.repository.listActiveFiles(), isEmpty);
    expect(await harness.blobs.has('blake3', hash), isFalse);
    final removed = await harness.repository.listTombstonedFiles();
    expect(removed, hasLength(1));
    expect(removed.first.hasLocalBytes, isFalse);
  });

  test('sourceKindLabel covers known kinds', () {
    expect(sourceKindLabel('whatsapp'), 'from WhatsApp');
    expect(sourceKindLabel('camera'), 'from Camera');
    expect(sourceKindLabel('download'), 'from Downloads');
    expect(sourceKindLabel('unknown'), isNull);
    expect(sourceKindLabel(null), isNull);
  });
}
