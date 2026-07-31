import 'package:injectable/injectable.dart';
import 'package:logger/logger.dart';

/// Tagged logger for audit/debug (console / logcat in v1).
@lazySingleton
class AppLog {
  AppLog()
      : _logger = Logger(
          printer: PrettyPrinter(
            methodCount: 0,
            errorMethodCount: 6,
            lineLength: 100,
            colors: false,
            printEmojis: false,
          ),
        );

  /// Test / silent variant.
  AppLog.silent() : _logger = Logger(level: Level.off);

  final Logger _logger;

  void fine(String tag, String message) => _logger.d(_fmt(tag, message));

  void info(String tag, String message) => _logger.i(_fmt(tag, message));

  void warn(String tag, String message) => _logger.w(_fmt(tag, message));

  void error(String tag, String message, [Object? error, StackTrace? stack]) {
    _logger.e(_fmt(tag, message), error: error, stackTrace: stack);
  }

  static String _fmt(String tag, String message) => '[$tag] $message';
}
