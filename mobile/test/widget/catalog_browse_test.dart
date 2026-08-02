import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
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

  testWidgets('ghost file shows provenance and Bring to phone', (tester) async {
    const ghost = CatalogFile(
      fileId: 'g1',
      contentHash: 'abc0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab',
      hashAlgo: 'blake3',
      mimeType: 'image/jpeg',
      sizeBytes: 100,
      title: 'IMG-WA0001.jpg',
      createdAt: '2026-08-03T00:00:00Z',
      updatedAt: '2026-08-03T00:00:00Z',
      primarySourceKind: 'whatsapp',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.ready,
          files: const [ghost],
          onPin: (_) async => null,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('from WhatsApp · on PC only'), findsOneWidget);

    await tester.tap(find.text('IMG-WA0001.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Bring to phone'), findsOneWidget);
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
