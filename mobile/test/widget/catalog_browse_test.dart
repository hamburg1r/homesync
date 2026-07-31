import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_page.dart';

import '../support/fixtures.dart';

void main() {
  testWidgets('lists listed files with tags', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.ready,
          files: [sampleFile],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('hello.txt'), findsOneWidget);
    expect(find.textContaining('listed'), findsWidgets);
    expect(find.textContaining('family'), findsOneWidget);
  });

  testWidgets('empty and degraded and error states', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.empty,
          files: [],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('No files yet'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.degraded,
          files: [sampleFile],
          statusMessage: 'connection refused',
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('offline/degraded'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.error,
          files: [],
          statusMessage: 'HTTP 503',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Could not reach catalog'), findsOneWidget);
  });
}
