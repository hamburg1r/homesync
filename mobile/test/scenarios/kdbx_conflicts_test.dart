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
          expect(request.url.queryParameters['state'], 'active');
          return http.Response(
            jsonEncode([
              {
                'conflict_id': conflictId,
                'file_id': fileId,
                'state': 'needs_secret',
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:01Z',
                'diff_summary': {'classification': 'needs_secret'},
                'resolved_content_hash': null,
                'candidates': [],
              },
              {
                'conflict_id': 'c-open',
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
    expect(listed, hasLength(2));
    expect(listed.any((c) => c.state == 'needs_secret'), isTrue);
    expect(listed.any((c) => c.state == 'open'), isTrue);
    expect(
      listed.firstWhere((c) => c.state == 'needs_secret').redactedDiffLabel,
      'Needs vault password on PC',
    );

    final file = await harness.api.resolveConflict(
      conflictId,
      KdbxResolveRequest.upload(contentHash: resolvedHash, sizeBytes: 6),
    );
    expect(file.fileId, fileId);
    expect(file.contentHash, resolvedHash);
  });

  test('contestedEntries + entries/candidate resolve bodies', () async {
    const conflictId = 'c-3';
    const fileId = 'vault-3';
    const removedUuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const modUuid = '11111111-2222-3333-4444-555555555555';
    final phoneHash = ContentHash.blake3Hex(utf8.encode('phone-vault'));

    Map<String, dynamic>? lastResolveBody;

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
                'diff_summary': {
                  'classification': 'real',
                  'removed_entry_uuids': [removedUuid],
                  'added_entry_uuids': <String>[],
                  'removed_entries': ['Root/Bank'],
                  'added_entries': <String>[],
                  'modified_entries': [
                    {
                      'uuid': modUuid,
                      'identity': 'Root/Work',
                      'fields': ['password'],
                    },
                  ],
                  'auto_mergeable': false,
                },
                'resolved_content_hash': null,
                'candidates': [
                  {
                    'content_hash': 'hash-base',
                    'size_bytes': 10,
                    'source_device_id': null,
                    'role': 'base',
                    'created_at': '2026-08-03T00:00:00Z',
                  },
                  {
                    'content_hash': phoneHash,
                    'size_bytes': 11,
                    'source_device_id': 'd1',
                    'role': 'incoming',
                    'created_at': '2026-08-03T00:00:01Z',
                  },
                ],
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' &&
            request.url.path.contains('/resolve')) {
          lastResolveBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            catalogFileJson(
              id: fileId,
              title: 'passes.kdbx',
              updatedAt: '2026-08-03T00:00:02Z',
              contentHash: phoneHash,
              sizeBytes: 11,
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' &&
            request.url.path.contains('/recheck')) {
          return http.Response(
            jsonEncode({
              'status': 'conflict',
              'conflict': {
                'conflict_id': conflictId,
                'file_id': fileId,
                'state': 'open',
                'created_at': '2026-08-03T00:00:00Z',
                'updated_at': '2026-08-03T00:00:03Z',
                'diff_summary': {'classification': 'real'},
                'resolved_content_hash': null,
                'candidates': [],
              },
              'file': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    );

    final listed = await harness.api.listConflicts();
    expect(listed, hasLength(1));
    final contested = listed.first.contestedEntries();
    expect(contested.map((e) => e.kind).toList(), ['removed', 'modified']);
    expect(contested.first.entryUuid, removedUuid);
    expect(contested.last.fields, ['password']);

    await harness.api.resolveConflict(
      conflictId,
      KdbxResolveRequest.entries(
        baseHash: 'hash-base',
        incomingHash: phoneHash,
        choices: [
          KdbxEntryChoice(entryUuid: removedUuid, keep: 'base'),
          KdbxEntryChoice(entryUuid: modUuid, keep: 'incoming'),
        ],
        note: 'resolved on phone',
      ),
    );
    expect(lastResolveBody!['mode'], 'entries');
    expect(lastResolveBody!['choices'], hasLength(2));
    expect(lastResolveBody!['base_hash'], 'hash-base');

    await harness.api.resolveConflict(
      conflictId,
      KdbxResolveRequest.candidate(
        contentHash: phoneHash,
        sizeBytes: 11,
      ),
    );
    expect(lastResolveBody!['mode'], 'candidate');
    expect(lastResolveBody!['content_hash'], phoneHash);

    final rechecked = await harness.api.recheckConflict(conflictId);
    expect(rechecked, isA<KdbxConflict>());
    expect((rechecked as KdbxConflict).state, 'open');
  });
}
