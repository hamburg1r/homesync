import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// Incremental hasher is not exported by blake3_dart's public barrel.
// ignore: implementation_imports
import 'package:blake3_dart/src/blake3_compact.dart' as b3;
import 'package:blake3_dart/blake3_dart.dart' as blake3;

class _Blake3FileRequest {
  const _Blake3FileRequest(this.path, this.sendPort);

  final String path;
  final SendPort sendPort;
}

/// Content hash helpers matching the Linux daemon (BLAKE3 / hex).
class ContentHash {
  ContentHash._();

  static const algo = 'blake3';
  static const chunkSize = 1024 * 1024;

  static String blake3Hex(Uint8List bytes) =>
      blake3.blake3Hex(bytes).toLowerCase();

  /// Stream-hash a file on a background isolate (keeps the UI responsive).
  ///
  /// When [onProgress] is set, reports bytes hashed after each 1 MiB chunk.
  static Future<String> blake3File(
    File file, {
    void Function(int bytesRead, int totalBytes)? onProgress,
  }) async {
    final total = await file.length();
    final safeTotal = total <= 0 ? 1 : total;
    if (onProgress == null) {
      return Isolate.run(() => _blake3FileSync(file.path));
    }

    onProgress(0, safeTotal);
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _blake3FileIsolate,
      _Blake3FileRequest(file.path, receive.sendPort),
    );
    try {
      await for (final message in receive) {
        if (message is String) {
          onProgress(safeTotal, safeTotal);
          return message;
        }
        if (message is List && message.length == 2) {
          onProgress(message[0] as int, message[1] as int);
        } else if (message is List &&
            message.isNotEmpty &&
            message[0] == 'error') {
          final detail = message.length > 1 ? '${message[1]}' : 'hash failed';
          throw StateError(detail);
        }
      }
      throw StateError('hash isolate exited without result');
    } finally {
      receive.close();
      isolate.kill(priority: Isolate.immediate);
    }
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

  @pragma('vm:entry-point')
  static void _blake3FileIsolate(_Blake3FileRequest request) {
    try {
      final file = File(request.path);
      final total = file.lengthSync();
      final safeTotal = total <= 0 ? 1 : total;
      final raf = file.openSync();
      try {
        final ctx = b3.HashContext.unkeyed();
        var done = 0;
        request.sendPort.send([0, safeTotal]);
        while (true) {
          final chunk = raf.readSync(chunkSize);
          if (chunk.isEmpty) break;
          ctx.update(chunk);
          done += chunk.length;
          request.sendPort.send([done, safeTotal]);
        }
        final out = Uint8List(32);
        ctx.finalize(out);
        request.sendPort.send(b3.asHexString(out).toLowerCase());
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      request.sendPort.send(['error', e.toString()]);
    }
  }
}
