/// Folder pin subscription: auto-pin under path prefix; structure + tombstone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/data/sync/folder_pin_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;
  late Directory localRoot;

  tearDown(() async {
    await harness.close();
    if (await localRoot.exists()) {
      await localRoot.delete(recursive: true);
    }
  });

  test(
    'reconcile pins prefix only; new files auto-pin; tombstone drops bytes',
    () async {
      const aBody = 'a\n';
      const bBody = 'bb\n';
      const otherBody = 'other\n';
      final aHash =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      final bHash =
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      final otherHash =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      final blobs = <String, String>{
        aHash: aBody,
        bHash: bBody,
        otherHash: otherBody,
      };

      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          if (request.method == 'PUT' &&
              request.url.path.contains('/availability/')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final parts = request.url.path.split('/');
            final fileId = parts[parts.indexOf('files') + 1];
            return availabilityOkResponse(
              fileId: fileId,
              mode: body['mode'] as String,
            );
          }
          if (request.method == 'GET' && request.url.path.contains('/blobs/')) {
            final hash = request.url.pathSegments.last;
            final payload = blobs[hash] ?? '';
            return http.Response(
              payload,
              200,
              headers: {
                'content-type': 'application/octet-stream',
                'content-length': '${payload.length}',
              },
            );
          }
          return http.Response(
            'unexpected ${request.method} ${request.url}',
            500,
          );
        }),
      );
      localRoot = Directory.systemTemp.createTempSync('homesync_folder_pin_');

      expect(pathMatchesFolderPinPrefix('vault/a.md', 'vault'), isTrue);
      expect(pathMatchesFolderPinPrefix('other/x.txt', 'vault'), isFalse);

      await harness.repository.applyDelta(
        CatalogDelta(
          nextCursor: 'v1:1',
          files: [
            CatalogFile(
              fileId: 'a',
              contentHash: aHash,
              hashAlgo: 'blake3',
              sizeBytes: aBody.length,
              title: 'a.md',
              createdAt: '2026-08-01T00:00:00Z',
              updatedAt: '2026-08-01T00:00:00Z',
            ),
            CatalogFile(
              fileId: 'other',
              contentHash: otherHash,
              hashAlgo: 'blake3',
              sizeBytes: otherBody.length,
              title: 'x.txt',
              createdAt: '2026-08-01T00:00:00Z',
              updatedAt: '2026-08-01T00:00:00Z',
            ),
          ],
          paths: [
            CatalogFilePath(
              id: 'pa',
              fileId: 'a',
              relativePath: 'vault/a.md',
              sourceKind: 'manual',
              seenAt: '2026-08-01T00:00:00Z',
            ),
            CatalogFilePath(
              id: 'po',
              fileId: 'other',
              relativePath: 'other/x.txt',
              sourceKind: 'manual',
              seenAt: '2026-08-01T00:00:00Z',
            ),
          ],
        ),
      );

      final sub = await harness.folderPinSubscriptions.add(
        name: 'Vault',
        pathPrefix: 'vault',
        localRoot: localRoot.path,
      );
      expect(await harness.folderPins.reconcile(sub), 1);
      expect(await File('${localRoot.path}/a.md').readAsString(), aBody);
      expect(await harness.repository.pinLocalPathForFileId('other'), isNull);

      final aMeta = await harness.repository.getFile('a');
      expect(aMeta?.availabilityMode, AvailabilityMode.pinned);
      expect(aMeta?.boundToServer, isTrue);

      await harness.repository.applyDelta(
        CatalogDelta(
          nextCursor: 'v1:2',
          files: [
            CatalogFile(
              fileId: 'b',
              contentHash: bHash,
              hashAlgo: 'blake3',
              sizeBytes: bBody.length,
              title: 'b.md',
              createdAt: '2026-08-02T00:00:00Z',
              updatedAt: '2026-08-02T00:00:00Z',
            ),
          ],
          paths: [
            CatalogFilePath(
              id: 'pb',
              fileId: 'b',
              relativePath: 'vault/sub/b.md',
              sourceKind: 'manual',
              seenAt: '2026-08-02T00:00:00Z',
            ),
          ],
        ),
      );
      expect(await harness.folderPins.reconcile(sub), 1);
      expect(await File('${localRoot.path}/sub/b.md').readAsString(), bBody);

      await harness.repository.applyTombstone(
        aMeta!.copyWith(
          deletedAt: '2026-08-03T00:00:00Z',
          updatedAt: '2026-08-03T00:00:00Z',
        ),
      );
      expect(await File('${localRoot.path}/a.md').exists(), isFalse);
    },
  );
}
