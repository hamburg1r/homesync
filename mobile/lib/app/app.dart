import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync_mobile/app/injection.dart';
import 'package:homesync_mobile/app/theme.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_cubit.dart';
import 'package:homesync_mobile/features/catalog/presentation/catalog_page.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';

class HomesyncApp extends StatelessWidget {
  const HomesyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = getIt<SettingsStore>();
    // Cubit above theme rebuilds so appearance toggles do not reset catalog state.
    return BlocProvider(
      create: (_) => getIt<CatalogCubit>()..start(),
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              final themes = homesyncThemes(
                useDynamicColor: settings.useDynamicColor,
                lightDynamic: lightDynamic,
                darkDynamic: darkDynamic,
              );
              return MaterialApp(
                title: 'Homesync',
                theme: themes.light,
                darkTheme: themes.dark,
                themeMode: settings.themeMode,
                home: CatalogPage(settings: settings),
              );
            },
          );
        },
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
    final themes = homesyncThemes(useDynamicColor: false);
    return MaterialApp(
      title: 'Homesync',
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: ThemeMode.system,
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
