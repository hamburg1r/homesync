/// Browse tree helpers + extension hide filters (view-only).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync_mobile/features/catalog/data/models/catalog_models.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_browse_tree.dart';

void main() {
  CatalogFile file({
    required String id,
    required String title,
    String? browsePath,
    LocalUploadState? upload,
  }) {
    return CatalogFile(
      fileId: id,
      contentHash: 'h',
      hashAlgo: 'blake3',
      sizeBytes: 1,
      title: title,
      createdAt: 't',
      updatedAt: 't',
      browsePath: browsePath,
      localUpload: upload,
    );
  }

  test('hide extension removes matching files only', () {
    final files = [
      file(id: '1', title: 'a.png', browsePath: 'a.png'),
      file(id: '2', title: 'b.jpg', browsePath: 'b.jpg'),
      file(id: '3', title: 'c.PNG', browsePath: 'dir/c.PNG'),
    ];
    final filtered = applyHiddenExtensions(files, hidden: {'png'});
    expect(filtered.map((f) => f.fileId), ['2']);
  });

  test('tree groups folders and shows pending spinner counts', () {
    final files = [
      file(
        id: '1',
        title: 'x.jpg',
        browsePath: 'Media/Images/x.jpg',
        upload: LocalUploadState.pending,
      ),
      file(id: '2', title: 'y.jpg', browsePath: 'Media/Images/y.jpg'),
      file(id: '3', title: 'z.txt', browsePath: 'Media/z.txt'),
    ];
    final top = buildTreeRows(files: files, treePrefix: '');
    expect(top, hasLength(1));
    expect(top.first, isA<CatalogTreeFolderRow>());
    final media = top.first as CatalogTreeFolderRow;
    expect(media.name, 'Media');
    expect(media.pendingCount, 1);

    final inside = buildTreeRows(files: files, treePrefix: 'Media');
    expect(inside.whereType<CatalogTreeFolderRow>().single.name, 'Images');
    expect(inside.whereType<CatalogTreeFileRow>().single.file.fileId, '3');

    final images = buildTreeRows(files: files, treePrefix: 'Media/Images');
    expect(images.whereType<CatalogTreeFileRow>(), hasLength(2));
  });
}
