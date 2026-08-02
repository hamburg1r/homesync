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
        pinService: harness.pinService,
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
        pinService: harness.pinService,
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
}
