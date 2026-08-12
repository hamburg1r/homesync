/// Offline Remove-from-PC queues DELETE and flushes when online again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  group('deletion outbox', () {
    late TestCatalogHarness harness;
    var allowDelete = false;
    var deleteHits = 0;

    setUp(() async {
      allowDelete = false;
      deleteHits = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            return http.Response(
              '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'hello.txt', updatedAt: 'a')}],
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
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/files/f1')) {
            deleteHits += 1;
            if (!allowDelete) {
              return http.Response('offline', 503);
            }
            return http.Response(
              catalogFileJson(
                id: 'f1',
                title: 'hello.txt',
                updatedAt: 'b',
                deletedAt: '2026-08-04T00:00:00Z',
              ),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected', 500);
        }),
      );
    });

    tearDown(() async {
      await harness.close();
    });

    CatalogCubit cubit() => CatalogCubit(
          repository: harness.repository,
          sync: harness.sync,
          api: harness.api,
          pinService: harness.pinService,
          thumbService: harness.thumbService,
          tracking: harness.tracking,
          scanner: harness.scanner,
          backgroundIngest: harness.backgroundIngest,
          deletionOutbox: harness.deletionOutbox,
          folderPins: harness.folderPins,
          folderPinSubscriptions: harness.folderPinSubscriptions,
          settings: harness.settings,
          log: harness.log,
        );

    test('failed DELETE enqueues optimistic tombstone; flush clears outbox',
        () async {
      final c = cubit();
      await c.start();
      expect(c.state.files, hasLength(1));

      final err = await c.deleteFromPc('f1');
      expect(err, isNull);
      expect(deleteHits, 1);
      expect(c.state.statusMessage, contains('Queued'));
      expect(c.state.pendingDeletionIds, contains('f1'));
      expect(c.state.files, isEmpty);

      final tombstoned = await harness.repository.getFile('f1');
      expect(tombstoned?.deletedAt, isNotNull);

      final queued = await harness.deletionOutbox.list();
      expect(queued, hasLength(1));
      expect(queued.single.fileId, 'f1');

      allowDelete = true;
      final flushed = await c.flushDeletionOutbox();
      expect(flushed, 1);
      expect(deleteHits, 2);
      expect(c.state.pendingDeletionIds, isEmpty);
      expect(await harness.deletionOutbox.list(), isEmpty);

      final again = await c.flushDeletionOutbox();
      expect(again, 0);
      expect(deleteHits, 2);

      await c.close();
    });

    test('Forget cancels pending PC delete', () async {
      final c = cubit();
      await c.start();

      await c.deleteFromPc('f1');
      expect(await harness.deletionOutbox.list(), hasLength(1));

      final err = await c.forgetLocalFile('f1');
      expect(err, isNull);
      expect(await harness.deletionOutbox.list(), isEmpty);
      expect(c.state.pendingDeletionIds, isEmpty);
      expect(await harness.repository.getFile('f1'), isNull);

      await c.close();
    });
  });
}
