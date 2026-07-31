import 'package:get_it/get_it.dart';
import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';
import 'package:homesync_mobile/app/injection.config.dart';

final GetIt getIt = GetIt.instance;

@InjectableInit()
Future<void> configureDependencies() async => getIt.init();

@module
abstract class AppRegisterModule {
  @preResolve
  @lazySingleton
  Future<SettingsStore> settingsStore(AppLog log) => SettingsStore.open(log);
}
