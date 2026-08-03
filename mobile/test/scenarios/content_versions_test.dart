/// Milestone 8 client exit check: bound path hash change → content version.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
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

  test('bound path hash change posts content, keeps file_id', () async {
    var creates = 0;
    var contentUpdates = 0;
    String? lastContentHash;

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final upload = mockBlobUploadResponse(request);
        if (upload != null) return upload;

        if (request.method == 'POST' &&
            request.url.path.contains('/content')) {
          contentUpdates += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.url.path, contains('/files/tracked-1/content'));
          expect(body['content_hash'], isNot(equals(lastContentHash)));
          lastContentHash = body['content_hash'] as String;
          return http.Response(
            '''
{
  "file_id": "tracked-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "notes.txt",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-08-03T00:00:00Z",
  "updated_at": "2026-08-03T00:00:01.000000Z",
  "deleted_at": null,
  "tags": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.method == 'POST' && request.url.path.endsWith('/files')) {
          creates += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          lastContentHash = body['content_hash'] as String;
          return http.Response(
            '''
{
  "file_id": "tracked-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "notes.txt",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-08-03T00:00:00Z",
  "updated_at": "2026-08-03T00:00:00.000000Z",
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
          return availabilityOkResponse(fileId: 'tracked-1', mode: 'pinned');
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    final file = File('${harness.scanRoot.path}/notes.txt');
    await file.writeAsBytes(Uint8List.fromList(utf8.encode('version one\n')));
    final hash1 = ContentHash.blake3Hex(await file.readAsBytes());

    await harness.tracking.addRule(
      name: 'docs',
      kind: TrackingRuleKind.file,
      patternOrUri: file.path,
      enabled: true,
    );

    final first = await harness.scanner.scanAndIngest();
    expect(first.tracked, 1);
    expect(first.ingested, 1);
    expect(creates, 1);
    expect(contentUpdates, 0);

    final afterFirst = await harness.tracking.getLocalFile(file.path);
    expect(afterFirst?.fileId, 'tracked-1');
    expect(afterFirst?.contentHash, hash1);
    expect(afterFirst?.isSynced, isTrue);

    // Unchanged rescan: mtime/size gate skips re-ingest.
    final noop = await harness.scanner.scanAndIngest();
    expect(noop.ingested, 0);
    expect(creates, 1);
    expect(contentUpdates, 0);

    // Rewrite bytes (size + mtime change) → version under same file_id.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await file.writeAsBytes(Uint8List.fromList(utf8.encode('version two edited\n')));
    final hash2 = ContentHash.blake3Hex(await file.readAsBytes());
    expect(hash2, isNot(equals(hash1)));

    final second = await harness.scanner.scanAndIngest();
    expect(second.tracked, 1);
    expect(second.ingested, 1);
    expect(creates, 1);
    expect(contentUpdates, 1);

    final afterSecond = await harness.tracking.getLocalFile(file.path);
    expect(afterSecond?.fileId, 'tracked-1');
    expect(afterSecond?.contentHash, hash2);
    expect(afterSecond?.isSynced, isTrue);
  });
}
