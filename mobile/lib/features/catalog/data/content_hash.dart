import 'dart:io';
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

  /// Stream-hash a file without loading it into RAM.
  static Future<String> blake3File(
    File file, {
    void Function(int bytesRead, int totalBytes)? onProgress,
  }) async {
    final total = await file.length();
    final ctx = b3.HashContext.unkeyed();
    var read = 0;
    final raf = await file.open();
    try {
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        ctx.update(chunk);
        read += chunk.length;
        onProgress?.call(read, total);
      }
    } finally {
      await raf.close();
    }
    final out = Uint8List(32);
    ctx.finalize(out);
    return b3.asHexString(out).toLowerCase();
  }
}
