import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_page.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class HomesyncApp extends StatelessWidget {
  const HomesyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F5D50),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Homesync',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
      ),
      home: BlocProvider(
        create: (_) => getIt<CatalogCubit>()..start(),
        child: CatalogPage(settings: getIt<SettingsStore>()),
      ),
    );
  }
}

/// Shown when prefs/DB bootstrap fails before DI is ready.
class BootstrapErrorApp extends StatelessWidget {
  const BootstrapErrorApp({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homesync',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Could not start Homesync'),
                const SizedBox(height: 8),
                Text(error.toString(), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
