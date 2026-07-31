import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _setupSqliteForTests();
  await testMain();
}

void _setupSqliteForTests() {
  if (!Platform.isLinux) return;
  open.overrideFor(OperatingSystem.linux, () {
    final fromEnv = Platform.environment['HOMESYNC_SQLITE3_LIB'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return DynamicLibrary.open(fromEnv);
    }
    final libPath = Platform.environment['LD_LIBRARY_PATH'];
    if (libPath != null) {
      for (final dir in libPath.split(':')) {
        if (dir.isEmpty) continue;
        for (final name in ['libsqlite3.so', 'libsqlite3.so.0']) {
          final candidate = File('$dir/$name');
          if (candidate.existsSync()) {
            return DynamicLibrary.open(candidate.path);
          }
        }
      }
    }
    for (final name in ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    throw StateError(
      'libsqlite3 not found; use nix develop .#mobile '
      '(sets HOMESYNC_SQLITE3_LIB / LD_LIBRARY_PATH)',
    );
  });
}
