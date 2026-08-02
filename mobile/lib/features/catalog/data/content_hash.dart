import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart' as blake3;

/// Content hash helpers matching the Linux daemon (BLAKE3 / hex).
class ContentHash {
  ContentHash._();

  static const algo = 'blake3';

  static String blake3Hex(Uint8List bytes) =>
      blake3.blake3Hex(bytes).toLowerCase();
}
