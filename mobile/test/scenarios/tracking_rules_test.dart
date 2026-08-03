/// Tracking rules: pattern compile, path source_kind, scan classify + ingest.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/tracking/data/source_kind.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_pattern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackingPattern', () {
    test('*.pdf matches basename case-insensitively', () {
      final p = TrackingPattern.compile('*.pdf');
      expect(p.matchesBasename('Report.PDF'), isTrue);
      expect(p.matchesBasename('photo.jpg'), isFalse);
      expect(p.matchesPath('/sdcard/Download/a.pdf'), isTrue);
    });

    test('normalizeRuleName defaults to misc', () {
      expect(normalizeRuleName(null), 'misc');
      expect(normalizeRuleName('  '), 'misc');
      expect(normalizeRuleName('Camera'), 'Camera');
    });
  });

  group('sourceKindFromPath', () {
    test('infers camera whatsapp download misc', () {
      expect(sourceKindFromPath('/sdcard/DCIM/Camera/a.jpg'), 'camera');
      expect(
        sourceKindFromPath('/sdcard/Android/media/com.whatsapp/Media/x.jpg'),
        'whatsapp',
      );
      expect(sourceKindFromPath('/sdcard/Download/doc.pdf'), 'download');
      expect(sourceKindFromPath('/sdcard/Documents/notes.txt'), 'misc');
    });
  });

  group('scan + ingest', () {
    late TestCatalogHarness harness;

    tearDown(() async {
      await harness.close();
    });

    test('regex rule tracks and ingests; other files untracked', () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['source_kind'], 'download');
            expect(body['title'], 'invoice.pdf');
            return http.Response(
              '''
{
  "file_id": "ing-pdf",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "invoice.pdf",
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
            return availabilityOkResponse(fileId: 'ing-pdf', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected', 500);
        }),
      );

      await File('${harness.scanRoot.path}/Download/invoice.pdf')
          .create(recursive: true)
          .then((f) => f.writeAsBytes(Uint8List.fromList(utf8.encode('pdf'))));
      await File('${harness.scanRoot.path}/Download/notes.txt')
          .create(recursive: true)
          .then((f) => f.writeAsString('txt'));

      final rule = await harness.tracking.addRule(
        name: '', // → misc
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.pdf',
        enabled: true,
      );
      expect(rule.name, 'misc');

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 1);
      expect(result.ingested, 1);
      expect(creates, 1);

      final tracked = await harness.tracking.listTracked();
      expect(tracked, hasLength(1));
      expect(tracked.first.title, 'invoice.pdf');
      expect(tracked.first.isSynced, isTrue);

      final untracked = await harness.tracking.listUntracked();
      expect(untracked.any((f) => f.title == 'notes.txt'), isTrue);
    });

    test('folder rule ingests; skips inaccessible sibling dirs', () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "ing-$creates",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
            return availabilityOkResponse(fileId: 'ing-1', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected', 500);
        }),
      );

      final blocked = Directory('${harness.scanRoot.path}/Android/data')
        ..createSync(recursive: true);
      final folder = Directory('${harness.scanRoot.path}/Important')
        ..createSync(recursive: true);
      await File('${folder.path}/note.md').writeAsString('hello');
      await File('${folder.path}/vault.kdbx')
          .writeAsBytes(Uint8List.fromList([1, 2, 3]));
      await Process.run('chmod', ['000', blocked.path]);
      addTearDown(() {
        Process.runSync('chmod', ['755', blocked.path]);
      });

      await harness.tracking.addRule(
        name: 'important',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
        enabled: true,
      );

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 2);
      expect(result.ingested, 2);
      expect(creates, 2);

      final tracked = await harness.tracking.listTracked();
      expect(
        tracked.map((f) => f.title).toSet(),
        {'note.md', 'vault.kdbx'},
      );
    });

    test('folder tracks nested subdirs and preserves relative_path', () async {
      final relativePaths = <String>[];
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            relativePaths.add(body['relative_path'] as String);
            return http.Response(
              '''
{
  "file_id": "nest-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
            return availabilityOkResponse(fileId: 'nest-1', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected', 500);
        }),
      );

      final folder = Directory('${harness.scanRoot.path}/WA')
        ..createSync(recursive: true);
      await File('${folder.path}/Media/foo/bar.jpg')
          .create(recursive: true)
          .then((f) => f.writeAsBytes(Uint8List.fromList([9, 9, 9])));

      await harness.tracking.addRule(
        name: 'whatsapp',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
        enabled: true,
      );

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 1);
      expect(result.ingested, 1);
      expect(relativePaths, ['track/whatsapp/Media/foo/bar.jpg']);
    });

    test('folder include-regex child filters; tags union applied', () async {
      final relativePaths = <String>[];
      final tagPuts = <List<String>>[];
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            relativePaths.add(body['relative_path'] as String? ?? '');
            return http.Response(
              '''
{
  "file_id": "jpg-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
              request.url.path.contains('/tags')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final tags = (body['tags'] as List<dynamic>).map((e) => '$e').toList()
              ..sort();
            tagPuts.add(tags);
            return http.Response(
              '''
{
  "file_id": "jpg-1",
  "content_hash": "deadbeef",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": 1,
  "title": "a.jpg",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-08-03T00:00:00Z",
  "updated_at": "2026-08-03T00:00:00.000000Z",
  "deleted_at": null,
  "tags": ${jsonEncode(tags)}
}
''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PUT' &&
              request.url.path.contains('/availability/')) {
            return availabilityOkResponse(fileId: 'jpg-1', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected ${request.method} ${request.url}', 500);
        }),
      );

      final folder = Directory('${harness.scanRoot.path}/Pics')
        ..createSync(recursive: true);
      await File('${folder.path}/a.jpg').writeAsBytes(Uint8List.fromList([1]));
      await File('${folder.path}/b.txt').writeAsString('skip');

      final parent = await harness.tracking.addRule(
        name: 'pics',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
        tags: const ['album'],
        sourceKind: 'misc',
        enabled: true,
      );
      await harness.tracking.addRule(
        name: 'pics',
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.jpg',
        parentId: parent.id,
        tags: const ['photo'],
        enabled: true,
      );

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 1);
      expect(result.ingested, 1);
      expect(relativePaths, ['track/pics/a.jpg']);
      expect(tagPuts, isNotEmpty);
      expect(tagPuts.first, ['album', 'photo']);

      final untracked = await harness.tracking.listUntracked();
      expect(untracked.any((f) => f.title == 'b.txt'), isTrue);
    });

    test('top-level rules default disabled; disable cancels pending', () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "dis-$creates",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
            return availabilityOkResponse(fileId: 'dis-1', mode: 'pinned');
          }
          return http.Response('unexpected', 500);
        }),
      );

      final folder = Directory('${harness.scanRoot.path}/Bulk')
        ..createSync(recursive: true);
      await File('${folder.path}/a.bin').writeAsBytes(Uint8List.fromList([1]));
      await File('${folder.path}/b.bin').writeAsBytes(Uint8List.fromList([2]));

      final rule = await harness.tracking.addRule(
        name: 'bulk',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
      );
      expect(rule.enabled, isFalse);

      final skipped = await harness.scanner.scanAndIngest();
      expect(skipped.tracked, 0);
      expect(skipped.ingested, 0);
      expect(creates, 0);

      await harness.scanner.setRuleEnabled(rule, true);
      final indexed = await harness.scanner.scanAndIngest(ingestMatches: false);
      expect(indexed.tracked, 2);
      expect(indexed.ingested, 0);
      final pending = await harness.tracking.listNeedingIngest();
      expect(pending, hasLength(2));

      final cancelled = await harness.scanner.setRuleEnabled(rule, false);
      expect(cancelled, 2);
      expect(await harness.tracking.listNeedingIngest(), isEmpty);
      final after = await harness.scanner.scanAndIngest();
      expect(after.ingested, 0);
      expect(creates, 0);
    });

    test('folder with include children never tracks whole tree', () async {
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            return http.Response('should not ingest', 500);
          }
          return http.Response('unexpected', 500);
        }),
      );

      final folder = Directory('${harness.scanRoot.path}/Mixed')
        ..createSync(recursive: true);
      await File('${folder.path}/keep.jpg').writeAsBytes(Uint8List.fromList([1]));
      await File('${folder.path}/skip.txt').writeAsString('no');

      final parent = await harness.tracking.addRule(
        name: 'mixed',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
        enabled: true,
      );
      // Child present but disabled ⇒ match nothing (not whole folder).
      await harness.tracking.addRule(
        name: 'mixed',
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.jpg',
        parentId: parent.id,
        enabled: false,
      );

      final none = await harness.scanner.scanAndIngest();
      expect(none.tracked, 0);
      expect(none.ingested, 0);
    });

    test('two matching rules union tags; edit propagates tags and source_kind',
        () async {
      final tagPuts = <List<String>>[];
      final patches = <Map<String, dynamic>>[];
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "multi-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
              request.url.path.contains('/tags')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final tags =
                (body['tags'] as List<dynamic>).map((e) => '$e').toList()
                  ..sort();
            tagPuts.add(tags);
            return http.Response(
              jsonEncode({
                'file_id': 'multi-1',
                'content_hash':
                    '448bd8dd9624154a690f8e84dc52d6f633ba7cd545c4d3c9b4e0f6a2f6fa71f4',
                'hash_algo': 'blake3',
                'mime_type': null,
                'size_bytes': 1,
                'title': 'shot.jpg',
                'notes': null,
                'taken_at': null,
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:01.000000Z',
                'deleted_at': null,
                'tags': tags,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PATCH' &&
              request.url.path.contains('/files/') &&
              !request.url.path.contains('/blob-uploads/')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            patches.add(body);
            return http.Response(
              jsonEncode({
                'file_id': 'multi-1',
                'content_hash':
                    '448bd8dd9624154a690f8e84dc52d6f633ba7cd545c4d3c9b4e0f6a2f6fa71f4',
                'hash_algo': 'blake3',
                'mime_type': null,
                'size_bytes': 1,
                'title': 'shot.jpg',
                'notes': null,
                'taken_at': null,
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:02.000000Z',
                'deleted_at': null,
                'tags': ['album', 'camera'],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PUT' &&
              request.url.path.contains('/availability/')) {
            return availabilityOkResponse(fileId: 'multi-1', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            'unexpected ${request.method} ${request.url}',
            500,
          );
        }),
      );

      final folder = Directory('${harness.scanRoot.path}/DCIM')
        ..createSync(recursive: true);
      await File('${folder.path}/shot.jpg').writeAsBytes(Uint8List.fromList([7]));

      final folderRule = await harness.tracking.addRule(
        name: 'camera',
        kind: TrackingRuleKind.folder,
        patternOrUri: folder.path,
        tags: const ['album'],
        enabled: true,
      );
      await harness.tracking.addRule(
        name: 'jpgs',
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.jpg',
        tags: const ['camera'],
        enabled: true,
      );

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 1);
      expect(result.ingested, 1);
      expect(tagPuts, isNotEmpty);
      expect(tagPuts.first, ['album', 'camera']);

      final edited = folderRule.copyWith(
        tags: const ['album', 'vacation'],
        sourceKind: 'camera',
      );
      await harness.tracking.updateRule(edited);
      final prop = await harness.scanner.propagateRuleEdit(
        before: folderRule,
        after: edited,
      );
      expect(prop.tagsUpdated, greaterThanOrEqualTo(1));
      expect(prop.sourceKindUpdated, greaterThanOrEqualTo(1));
      expect(
        tagPuts.last,
        containsAll(['album', 'camera', 'vacation']),
      );
      expect(patches.any((p) => p['source_kind'] == 'camera'), isTrue);
    });

    test('file rule ingests only the selected path', () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "ing-$creates",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
            return availabilityOkResponse(fileId: 'ing-1', mode: 'pinned');
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected', 500);
        }),
      );

      final keep = File('${harness.scanRoot.path}/keep-me.txt')
        ..writeAsStringSync('tracked');
      File('${harness.scanRoot.path}/ignore-me.txt').writeAsStringSync('nope');

      await harness.tracking.addRule(
        name: 'one',
        kind: TrackingRuleKind.file,
        patternOrUri: keep.path,
        enabled: true,
      );

      final result = await harness.scanner.scanAndIngest();
      expect(result.tracked, 1);
      expect(result.ingested, 1);
      expect(creates, 1);

      final tracked = await harness.tracking.listTracked();
      expect(tracked, hasLength(1));
      expect(tracked.single.title, 'keep-me.txt');
      // Original path is SoT on phone — no duplicate in pin store.
      expect(
        await harness.blobs.has('blake3', tracked.single.contentHash!),
        isFalse,
      );
    });

    test('pending tracked files stay pending until ingest; chip not listed',
        () async {
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          return http.Response('unexpected ingest', 500);
        }),
      );

      final file = File('${harness.scanRoot.path}/Download/soon.pdf')
        ..createSync(recursive: true);
      await file.writeAsString('pending-bytes');

      await harness.tracking.addRule(
        name: 'pdfs',
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.pdf',
        enabled: true,
      );

      var indexedPending = false;
      final result = await harness.scanner.scanAndIngest(
        ingestMatches: false,
        onIndexed: () async {
          final tracked = await harness.tracking.listTracked();
          expect(tracked, hasLength(1));
          expect(tracked.single.ingestStatus, IngestStatus.pending);
          indexedPending = true;
        },
      );
      expect(result.tracked, 1);
      expect(result.ingested, 0);
      expect(indexedPending, isTrue);
      expect(await harness.tracking.listNeedingIngest(), hasLength(1));

      final pending = CatalogFile(
        fileId: 'local:${file.path}',
        contentHash: 'pending',
        hashAlgo: 'blake3',
        sizeBytes: 13,
        title: 'soon.pdf',
        createdAt: 't',
        updatedAt: 't',
        availabilityMode: AvailabilityMode.listed,
        hasLocalBytes: true,
        primarySourceKind: 'download',
        localUpload: LocalUploadState.pending,
      );
      expect(pending.statusLabel(), 'pending');
      expect(pending.statusLabel(activeUploadPhase: 'uploading'), 'uploading');
      expect(pending.provenanceSubtitle, contains('pending upload'));
      expect(pending.isGhost, isFalse);
    });

    test('background ingest runner uploads after scan without blocking', () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          final upload = mockBlobUploadResponse(request);
          if (upload != null) return upload;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "bg-$creates",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "${body['title']}",
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
            return availabilityOkResponse(fileId: 'bg-$creates', mode: 'pinned');
          }
          return http.Response('unexpected', 500);
        }),
      );

      final f = File('${harness.scanRoot.path}/Download/later.pdf')
        ..createSync(recursive: true);
      await f.writeAsString('bg-upload');
      await harness.tracking.addRule(
        name: 'pdfs',
        kind: TrackingRuleKind.regex,
        patternOrUri: '*.pdf',
        enabled: true,
      );

      await harness.scanner.scanAndIngest(ingestMatches: false);
      expect(await harness.tracking.listNeedingIngest(), hasLength(1));

      await harness.backgroundIngest.kick();
      expect(creates, 1);
      expect(await harness.tracking.listNeedingIngest(), isEmpty);
      expect((await harness.tracking.listTracked()).single.isSynced, isTrue);
    });

    test('failed ingest with unchanged mtime reuses digest (no rehash gate)',
        () async {
      var creates = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
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
          if (upload != null) {
            return upload;
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/files')) {
            creates += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '''
{
  "file_id": "ghost-1",
  "content_hash": "${body['content_hash']}",
  "hash_algo": "blake3",
  "mime_type": null,
  "size_bytes": ${body['size_bytes']},
  "title": "ghost.bin",
  "notes": null,
  "taken_at": null,
  "created_at": "2026-08-01T00:00:00Z",
  "updated_at": "2026-08-01T00:00:00Z",
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
            return availabilityOkResponse(fileId: 'ghost-1', mode: 'pinned');
          }
          return http.Response('unexpected', 500);
        }),
      );

      final file = File('${harness.scanRoot.path}/ghost.bin')
        ..writeAsBytesSync(Uint8List.fromList(List<int>.filled(64, 7)));
      await harness.tracking.addRule(
        name: 'iso',
        kind: TrackingRuleKind.file,
        patternOrUri: file.path,
        enabled: true,
      );

      final first = await harness.scanner.scanAndIngest();
      expect(first.ingested, 1);
      expect(creates, 1);
      final synced = await harness.tracking.getLocalFile(file.path);
      expect(synced?.isSynced, isTrue);
      expect(synced?.contentHash, isNotNull);
      expect(synced?.mtimeMs, isNotNull);
      final digest = synced!.contentHash!;

      // Simulate upload abort after hash, before the server assigned file_id.
      await harness.tracking.upsertLocalFile(
        LocalTrackedFile(
          localPath: synced.localPath,
          ruleId: synced.ruleId,
          fileId: null,
          contentHash: digest,
          title: synced.title,
          sizeBytes: synced.sizeBytes,
          mtimeMs: synced.mtimeMs,
          mimeType: synced.mimeType,
          sourceKind: synced.sourceKind,
          seenAt: synced.seenAt,
          ingestStatus: IngestStatus.pending,
        ),
      );

      final enqueued = await harness.scanner.enqueuePending();
      expect(enqueued, 1);
      final queued = await harness.ingestQueue.list();
      expect(queued, hasLength(1));
      expect(queued.single.contentHash, digest);
      // Rescan must not clear the digest when size/mtime are unchanged.
      await harness.scanner.scanAndIngest(ingestMatches: false);
      final again = await harness.tracking.getLocalFile(file.path);
      expect(again?.contentHash, digest);
      expect(again?.ingestStatus, IngestStatus.pending);
    });
  });
}
