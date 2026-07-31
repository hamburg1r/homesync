/// Thin typed failure for API / sync surfaces.
class AppException implements Exception {
  AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
