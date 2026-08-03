/// Milestone 9 client: KeePass content 202 opens outbox; resolve closes it.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/content_hash.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/models/kdbx_conflict.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('updateFileContent 202 throws KdbxConflictPendingException', () async {
    const fileId = 'vault-1';
    const conflictId = 'c-1';
    final payload = utf8.encode('fake-kdbx-bytes-v2');
    final hash = ContentHash.blake3Hex(payload);

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'POST' &&
            request.url.path.contains('/content')) {
          return http.Response(
            jsonEncode({
              'status': 'conflict',
              'conflict': {
                'conflict_id': conflictId,
                'file_id': fileId,
                'state': 'open',
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:01Z',
                'diff_summary': {
                  'classification': 'real',
                  'modified_entries': [
                    {
                      'identity': 'Root/Bank',
                      'fields': ['password'],
                    },
                  ],
                },
                'resolved_content_hash': null,
                'candidates': [
                  {
                    'content_hash': 'hash-a',
                    'size_bytes': 10,
                    'source_device_id': null,
                    'role': 'base',
                    'created_at': '2026-08-03T00:00:00Z',
                  },
                  {
                    'content_hash': hash,
                    'size_bytes': payload.length,
                    'source_device_id': 'd1',
                    'role': 'incoming',
                    'created_at': '2026-08-03T00:00:01Z',
                  },
                ],
              },
              'file': null,
            }),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    );

    await expectLater(
      harness.api.updateFileContent(
        fileId,
        FileContentRequest(
          contentHash: hash,
          sizeBytes: payload.length,
        ),
      ),
      throwsA(
        isA<KdbxConflictPendingException>().having(
          (e) => e.conflict.conflictId,
          'conflictId',
          conflictId,
        ),
      ),
    );
  });

  test('listConflicts + resolveConflict parse responses', () async {
    const conflictId = 'c-2';
    const fileId = 'vault-2';
    final resolvedHash = ContentHash.blake3Hex(utf8.encode('merged'));

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/devices')) {
          return deviceOkResponse();
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/conflicts')) {
          return http.Response(
            jsonEncode([
              {
                'conflict_id': conflictId,
                'file_id': fileId,
                'state': 'open',
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:01Z',
                'diff_summary': {'classification': 'real'},
                'resolved_content_hash': null,
                'candidates': [],
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' &&
            request.url.path.contains('/resolve')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['content_hash'], resolvedHash);
          return http.Response(
            catalogFileJson(
              id: fileId,
              title: 'passes.kdbx',
              updatedAt: '2026-08-03T00:00:02Z',
              contentHash: resolvedHash,
              sizeBytes: 6,
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    );

    final listed = await harness.api.listConflicts();
    expect(listed, hasLength(1));
    expect(listed.first.conflictId, conflictId);
    expect(listed.first.redactedDiffLabel, isNotEmpty);

    final file = await harness.api.resolveConflict(
      conflictId,
      FileContentRequest(contentHash: resolvedHash, sizeBytes: 6),
    );
    expect(file.fileId, fileId);
    expect(file.contentHash, resolvedHash);
  });
}
