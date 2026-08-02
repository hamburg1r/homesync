import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device JPEG thumb cache (listed-mode previews; not full blobs).
///
/// Layout: `thumbs/<hh>/<hh>/<fullhash>.jpg` (content-addressed).
@lazySingleton
class LocalThumbStore {
  LocalThumbStore(this._log);

  /// Test constructor with an explicit root (no path_provider).
  LocalThumbStore.forRoot(this._log, Directory root) : _rootOverride = root;

  final AppLog _log;
  Directory? _rootOverride;
  Directory? _cachedRoot;

  Future<Directory> _root() async {
    if (_rootOverride != null) return _rootOverride!;
    if (_cachedRoot != null) return _cachedRoot!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'homesync_thumbs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedRoot = dir;
    return dir;
  }

  Future<File> pathFor(String hexHash) async {
    final digest = hexHash.toLowerCase();
    if (digest.length < 4) {
      throw ArgumentError('content hash too short for fan-out');
    }
    final root = await _root();
    return File(
      p.join(
        root.path,
        digest.substring(0, 2),
        digest.substring(2, 4),
        '$digest.jpg',
      ),
    );
  }

  Future<bool> has(String hexHash) async {
    final file = await pathFor(hexHash);
    return file.exists();
  }

  Future<void> write(String hexHash, Uint8List bytes) async {
    final file = await pathFor(hexHash);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
    _log.info(
      'thumbs',
      'wrote ${bytes.length} bytes ${hexHash.substring(0, 8)}…',
    );
  }

  Future<Uint8List?> read(String hexHash) async {
    final file = await pathFor(hexHash);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> delete(String hexHash) async {
    final file = await pathFor(hexHash);
    if (await file.exists()) {
      await file.delete();
      _log.info('thumbs', 'deleted ${hexHash.substring(0, 8)}…');
    }
  }
}
