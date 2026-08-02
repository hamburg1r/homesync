/// Tracking rules: pattern compile, path source_kind, scan classify + ingest.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
          if (request.method == 'PUT' && request.url.path.contains('/blobs/')) {
            return http.Response('', 201);
          }
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
          if (request.method == 'PUT' && request.url.path.contains('/blobs/')) {
            return http.Response('', 201);
          }
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
  });
}
