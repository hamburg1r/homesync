import 'dart:io';
import 'dart:typed_data';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device content-addressed pin store (filesystem, not SQLite).
///
/// Layout mirrors the server: `pins/<algo>/<hh>/<hh>/<fullhash>`.
@lazySingleton
class LocalBlobStore {
  LocalBlobStore(this._log);

  /// Test constructor with an explicit root (no path_provider).
  LocalBlobStore.forRoot(this._log, Directory root) : _rootOverride = root;

  final AppLog _log;
  Directory? _rootOverride;
  Directory? _cachedRoot;

  Future<Directory> _root() async {
    if (_rootOverride != null) return _rootOverride!;
    if (_cachedRoot != null) return _cachedRoot!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'homesync_pins'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedRoot = dir;
    return dir;
  }

  Future<File> pathFor(String algo, String hexHash) async {
    final digest = hexHash.toLowerCase();
    if (digest.length < 4) {
      throw ArgumentError('content hash too short for fan-out');
    }
    final root = await _root();
    return File(
      p.join(
        root.path,
        algo,
        digest.substring(0, 2),
        digest.substring(2, 4),
        digest,
      ),
    );
  }

  Future<bool> has(String algo, String hexHash) async {
    final file = await pathFor(algo, hexHash);
    return file.exists();
  }

  Future<int> sizeOf(String algo, String hexHash) async {
    final file = await pathFor(algo, hexHash);
    if (!await file.exists()) return 0;
    return file.length();
  }

  Future<void> write(String algo, String hexHash, Uint8List bytes) async {
    final file = await pathFor(algo, hexHash);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
    _log.info(
      'blobs',
      'wrote ${bytes.length} bytes $algo/${hexHash.substring(0, 8)}…',
    );
  }

  /// Copy [source] into the pin store via chunked IO (no full-file RAM buffer).
  Future<void> copyFile(
    String algo,
    String hexHash,
    File source, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final dest = await pathFor(algo, hexHash);
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.tmp');
    final total = await source.length();
    var copied = 0;
    final reader = source.openRead();
    final sink = tmp.openWrite();
    try {
      await for (final chunk in reader) {
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, total);
      }
      await sink.flush();
      await sink.close();
      if (await dest.exists()) {
        await dest.delete();
      }
      await tmp.rename(dest.path);
    } catch (_) {
      await sink.close();
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    _log.info(
      'blobs',
      'copied $copied bytes $algo/${hexHash.substring(0, 8)}…',
    );
  }

  Future<Uint8List?> read(String algo, String hexHash) async {
    final file = await pathFor(algo, hexHash);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Stream pin bytes for upload without loading the whole object.
  Stream<List<int>> openRead(String algo, String hexHash) async* {
    final file = await pathFor(algo, hexHash);
    if (!await file.exists()) {
      throw StateError('blob missing $algo/$hexHash');
    }
    yield* file.openRead();
  }

  Future<void> delete(String algo, String hexHash) async {
    final file = await pathFor(algo, hexHash);
    if (await file.exists()) {
      await file.delete();
      _log.info('blobs', 'deleted $algo/${hexHash.substring(0, 8)}…');
    }
  }

  /// Total bytes under the pin root (for disk budget).
  Future<int> totalBytes() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}
