/// Milestone 7 client exit check: listed-mode thumbs + local search.
///
/// Thumb fetch caches a small JPEG without materializing the full blob.
/// Search filters the local catalog by title / tags.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('thumb sync caches JPEG without full blob; search filters locally',
      () async {
    final hash =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    // Minimal valid-ish JPEG header bytes (server would send a real thumb).
    final thumbJpeg = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
    ]);
    var thumbHits = 0;

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
  "next_cursor": "v1:a|f2",
  "files": [
    ${catalogFileJson(id: 'f1', title: 'Family picnic.jpg', updatedAt: 'a', contentHash: hash, sizeBytes: 99999, mimeType: 'image/jpeg', hasThumb: true, tags: ['family'])},
    ${catalogFileJson(id: 'f2', title: 'receipt.txt', updatedAt: 'a', contentHash: 'bb$hash'.substring(0, 64), sizeBytes: 12, mimeType: 'text/plain', tags: ['work'])}
  ],
  "tags": [
    {"tag_id": "t1", "name": "family", "color": null},
    {"tag_id": "t2", "name": "work", "color": null}
  ],
  "file_tags": [
    {"file_id": "f1", "tag_id": "t1"},
    {"file_id": "f2", "tag_id": "t2"}
  ],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path.contains('/thumbs/')) {
          thumbHits += 1;
          return http.Response.bytes(
            thumbJpeg,
            200,
            headers: {
              'content-type': 'image/jpeg',
              'content-length': '${thumbJpeg.length}',
            },
          );
        }
        if (request.method == 'GET' && request.url.path.contains('/blobs/')) {
          return http.Response('should not fetch full blob for thumb', 500);
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    expect((await harness.sync.sync()).ok, isTrue);
    final listed = await harness.repository.listActiveFiles();
    expect(listed, hasLength(2));

    final image = listed.firstWhere((f) => f.fileId == 'f1');
    expect(image.canShowThumb, isTrue);
    expect(image.hasLocalBytes, isFalse);

    final path = await harness.thumbService.ensureThumb(image);
    expect(path, isNotNull);
    expect(await path!.exists(), isTrue);
    expect(await path.length(), thumbJpeg.length);
    expect(await harness.blobs.has(image.hashAlgo, image.contentHash), isFalse);
    expect(thumbHits, 1);

    // Cache hit — no second GET.
    final again = await harness.thumbService.ensureThumb(image);
    expect(again!.path, path.path);
    expect(thumbHits, 1);

    final text = listed.firstWhere((f) => f.fileId == 'f2');
    expect(await harness.thumbService.ensureThumb(text), isNull);

    final cubit = CatalogCubit(
      repository: harness.repository,
      sync: harness.sync,
      api: harness.api,
      pinService: harness.pinService,
      thumbService: harness.thumbService,
      tracking: harness.tracking,
      scanner: harness.scanner,
      settings: harness.settings,
      log: harness.log,
    );
    await cubit.start();
    expect(cubit.state.files, hasLength(2));

    await cubit.setSearchQuery('picnic');
    expect(cubit.state.files, hasLength(1));
    expect(cubit.state.files.first.fileId, 'f1');

    await cubit.setSearchQuery('work');
    expect(cubit.state.files, hasLength(1));
    expect(cubit.state.files.first.fileId, 'f2');

    await cubit.setSearchQuery('FAMILY');
    expect(cubit.state.files, hasLength(1));
    expect(cubit.state.files.first.fileId, 'f1');

    await cubit.setSearchQuery('');
    expect(cubit.state.files, hasLength(2));

    await cubit.close();
  });

  test('API searchFiles parses has_thumb from server', () async {
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/files')) {
          expect(request.url.queryParameters['q'], 'picnic');
          return http.Response(
            '''
[
  ${catalogFileJson(id: 'f1', title: 'Family picnic.jpg', updatedAt: 'a', mimeType: 'image/jpeg', hasThumb: true, tags: ['family'])}
]
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected', 500);
      }),
    );

    final hits = await harness.api.searchFiles(q: 'picnic');
    expect(hits, hasLength(1));
    expect(hits.first.hasThumb, isTrue);
    expect(hits.first.canShowThumb, isTrue);
  });
}
