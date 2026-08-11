/// Phone can set tags via PUT /v1/files/{id}/tags and update the local mirror.
library;

import 'dart:convert';

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

  test('setFileTags: PUT tags + listTags updates local catalog names', () async {
    var putBody = <String, dynamic>{};
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
  "next_cursor": "v1:a|f1",
  "files": [${catalogFileJson(id: 'f1', title: 'photo.jpg', updatedAt: 'a')}],
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
        if (request.method == 'PUT' && request.url.path.endsWith('/tags')) {
          putBody = jsonDecode(request.body) as Map<String, dynamic>;
          final tags = (putBody['tags'] as List<dynamic>).cast<String>();
          return http.Response(
            catalogFileJson(
              id: 'f1',
              title: 'photo.jpg',
              updatedAt: 'b',
              tags: tags,
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path.endsWith('/tags')) {
          return http.Response(
            '''
[
  {"tag_id": "t1", "name": "family", "color": null},
  {"tag_id": "t2", "name": "receipts", "color": null}
]
''',
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
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cubit.state.files, hasLength(1));
    expect(cubit.state.files.first.tags, isEmpty);

    final err = await cubit.setFileTags('f1', ['family', 'receipts']);
    expect(err, isNull);
    expect(putBody['tags'], ['family', 'receipts']);

    final files = await harness.repository.listActiveFiles();
    expect(files, hasLength(1));
    expect(files.first.tags.toSet(), {'family', 'receipts'});
    expect(files.first.updatedAt, 'b');

    final suggestions = await cubit.listTagSuggestions();
    expect(suggestions.toSet(), containsAll(['family', 'receipts']));

    // Remove one tag.
    final err2 = await cubit.setFileTags('f1', ['family']);
    expect(err2, isNull);
    final after = await harness.repository.listActiveFiles();
    expect(after.first.tags, ['family']);

    await cubit.close();
  });

  test('setFileTags rejects local: pending ingest ids', () async {
    harness = await TestCatalogHarness.open(
      MockClient((_) async => http.Response('unused', 500)),
    );
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
    final err = await cubit.setFileTags('local:abc', ['family']);
    expect(err, contains('Sync this file first'));
    await cubit.close();
  });
}
