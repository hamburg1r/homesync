import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_view.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/tracking/data/tracking_models.dart';

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

  testWidgets('file detail shows path when resolver provided', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.ready,
          files: const [
            CatalogFile(
              fileId: 'f1',
              contentHash:
                  'abc0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab',
              hashAlgo: 'blake3',
              mimeType: 'text/plain',
              sizeBytes: 12,
              title: 'hello.txt',
              createdAt: '2026-07-31T00:00:00Z',
              updatedAt: '2026-07-31T00:00:00.000000Z',
              tags: ['family'],
              hasLocalBytes: true,
              availabilityMode: AvailabilityMode.pinned,
            ),
          ],
          onResolveLocalPath: (_) async => '/storage/emulated/0/Download/hello.txt',
          onCatalogRelativePath: (_) async => 'ingest/download/hello.txt',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('hello.txt'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('/storage/emulated/0/Download/hello.txt'),
      findsOneWidget,
    );
    expect(find.textContaining('ingest/download/hello.txt'), findsOneWidget);
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

  testWidgets('drawer lists Removed from PC browse mode', (tester) async {
    BrowseMode? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogBrowseView(
          state: CatalogViewState.ready,
          files: const [],
          onSelectBrowse: (mode, {ruleId, title}) => selected = mode,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    // Show checkboxes push this row below the fold — scroll the drawer list.
    final drawerScrollable = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(Scrollable),
    );
    final removedIcon = find.descendant(
      of: find.byType(Drawer),
      matching: find.byIcon(Icons.delete_outline),
    );
    await tester.scrollUntilVisible(
      removedIcon,
      120,
      scrollable: drawerScrollable.first,
    );
    await tester.pumpAndSettle();
    await tester.tap(removedIcon);
    await tester.pumpAndSettle();
    expect(selected, BrowseMode.removedFromPc);
  });
}
