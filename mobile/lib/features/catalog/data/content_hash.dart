import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// Incremental hasher is not exported by blake3_dart's public barrel.
// ignore: implementation_imports
import 'package:blake3_dart/src/blake3_compact.dart' as b3;
import 'package:blake3_dart/blake3_dart.dart' as blake3;

/// Content hash helpers matching the Linux daemon (BLAKE3 / hex).
class ContentHash {
  ContentHash._();

  static const algo = 'blake3';
  static const chunkSize = 1024 * 1024;

  static String blake3Hex(Uint8List bytes) =>
      blake3.blake3Hex(bytes).toLowerCase();

  /// Stream-hash a file on a background isolate (keeps the UI responsive).
  ///
  /// Progress is coarse (start/end only) because hashing is CPU-bound off-thread.
  static Future<String> blake3File(
    File file, {
    void Function(int bytesRead, int totalBytes)? onProgress,
  }) async {
    final total = await file.length();
    onProgress?.call(0, total <= 0 ? 1 : total);
    final hash = await Isolate.run(() => _blake3FileSync(file.path));
    onProgress?.call(total <= 0 ? 1 : total, total <= 0 ? 1 : total);
    return hash;
  }

  static String _blake3FileSync(String path) {
    final raf = File(path).openSync();
    try {
      final ctx = b3.HashContext.unkeyed();
      while (true) {
        final chunk = raf.readSync(chunkSize);
        if (chunk.isEmpty) break;
        ctx.update(chunk);
      }
      final out = Uint8List(32);
      ctx.finalize(out);
      return b3.asHexString(out).toLowerCase();
    } finally {
      raf.closeSync();
    }
  }
}
