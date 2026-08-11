import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refresh ok', () {
    late TestCatalogHarness harness;

    setUp(() async {
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST') return deviceOkResponse();
          return http.Response(
            '''
{
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'hello.txt', updatedAt: 'a', tags: ['family'])}],
  "tags": [{"tag_id": "t1", "name": "family", "color": null}],
  "file_tags": [{"file_id": "f1", "tag_id": "t1"}],
  "paths": [],
  "availability": []
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });

    tearDown(() async {
      await harness.close();
    });

    blocTest<CatalogCubit, CatalogState>(
      'refresh ok → ready with files',
      build: () => CatalogCubit(
        repository: harness.repository,
        sync: harness.sync,
        api: harness.api,
        pinService: harness.pinService,
        thumbService: harness.thumbService,
        tracking: harness.tracking,
        scanner: harness.scanner,
        backgroundIngest: harness.backgroundIngest,
        deletionOutbox: harness.deletionOutbox,
        settings: harness.settings,
        log: harness.log,
      ),
      act: (cubit) => cubit.start(),
      wait: const Duration(milliseconds: 100),
      verify: (cubit) {
        expect(cubit.state.viewState, CatalogViewState.ready);
        expect(cubit.state.files, hasLength(1));
        expect(cubit.state.files.first.displayName, 'hello.txt');
        expect(cubit.state.refreshing, isFalse);
      },
    );
  });

  group('degraded', () {
    late TestCatalogHarness harness;

    setUp(() async {
      harness = await TestCatalogHarness.open(
        MockClient((_) async => http.Response('down', 503)),
      );
      await harness.repository.applyDelta(
        CatalogDelta(
          nextCursor: 'v1:a|f1',
          files: [sampleFile],
          tags: const [CatalogTag(tagId: 't1', name: 'family')],
          fileTags: const [CatalogFileTag(fileId: 'f1', tagId: 't1')],
        ),
      );
    });

    tearDown(() async {
      await harness.close();
    });

    blocTest<CatalogCubit, CatalogState>(
      'sync failure with local rows → degraded',
      build: () => CatalogCubit(
        repository: harness.repository,
        sync: harness.sync,
        api: harness.api,
        pinService: harness.pinService,
        thumbService: harness.thumbService,
        tracking: harness.tracking,
        scanner: harness.scanner,
        backgroundIngest: harness.backgroundIngest,
        deletionOutbox: harness.deletionOutbox,
        settings: harness.settings,
        log: harness.log,
      ),
      seed: () => const CatalogState(
        viewState: CatalogViewState.ready,
        files: [sampleFile],
      ),
      act: (cubit) => cubit.refresh(),
      wait: const Duration(milliseconds: 50),
      verify: (cubit) {
        expect(cubit.state.viewState, CatalogViewState.degraded);
        expect(cubit.state.files, isNotEmpty);
        expect(cubit.state.statusMessage, isNotNull);
      },
    );
  });

  group('sync pause + remove from PC', () {
    late TestCatalogHarness harness;
    var deltaHits = 0;
    var deleteHits = 0;

    setUp(() async {
      deltaHits = 0;
      deleteHits = 0;
      harness = await TestCatalogHarness.open(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/devices')) {
            return deviceOkResponse();
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/catalog/delta')) {
            deltaHits += 1;
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
            return http.Response(
              catalogFileJson(
                id: 'f1',
                title: 'hello.txt',
                updatedAt: 'b',
                deletedAt: '2026-08-03T12:00:00Z',
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

    test('syncEnabled false skips delta', () async {
      await harness.settings.setSyncEnabled(false);
      final cubit = CatalogCubit(
        repository: harness.repository,
        sync: harness.sync,
        api: harness.api,
        pinService: harness.pinService,
        thumbService: harness.thumbService,
        tracking: harness.tracking,
        scanner: harness.scanner,
        backgroundIngest: harness.backgroundIngest,
        deletionOutbox: harness.deletionOutbox,
        settings: harness.settings,
        log: harness.log,
      );
      await cubit.start();
      expect(deltaHits, 0);
      expect(cubit.state.syncEnabled, isFalse);
      expect(cubit.state.statusMessage, contains('Sync is off'));
      await cubit.close();
    });

    test('deleteFromPc soft-deletes and drops listing', () async {
      final cubit = CatalogCubit(
        repository: harness.repository,
        sync: harness.sync,
        api: harness.api,
        pinService: harness.pinService,
        thumbService: harness.thumbService,
        tracking: harness.tracking,
        scanner: harness.scanner,
        backgroundIngest: harness.backgroundIngest,
        deletionOutbox: harness.deletionOutbox,
        settings: harness.settings,
        log: harness.log,
      );
      await cubit.start();
      expect(cubit.state.files, hasLength(1));

      final err = await cubit.deleteFromPc('f1');
      expect(err, isNull);
      expect(deleteHits, 1);
      expect(cubit.state.files, isEmpty);
      await cubit.close();
    });
  });
}
