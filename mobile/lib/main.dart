import 'package:flutter/material.dart';
import 'package:homesync_mobile/app/app.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/catalog/data/sync/background_ingest_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initBackgroundIngestService();
  await _boot();
}

Future<void> _boot() async {
  try {
    await configureDependencies();
    getIt<AppLog>().info('di', 'dependencies ready');
    runApp(const HomesyncApp());
  } catch (e, st) {
    // Logger may be unavailable if DI failed early.
    // ignore: avoid_print
    print('bootstrap failed: $e\n$st');
    runApp(
      BootstrapErrorApp(
        error: e,
        onRetry: () {
          runApp(
            const MaterialApp(
              home: Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
            ),
          );
          getIt.reset();
          _boot();
        },
      ),
    );
  }
}
