/// Root of the typed error system (§43). Every user-visible failure maps to
/// a human sentence + likely causes + suggested actions; raw detail is kept
/// for the advanced log view.
class AppError implements Exception {
  AppError(this.userMessage, {this.likelyCauses = const [], this.raw});

  final String userMessage;
  final List<String> likelyCauses;
  final Object? raw;

  @override
  String toString() => '$runtimeType: $userMessage (${raw ?? ''})';
}

class ParseError extends AppError {
  ParseError(super.userMessage, {super.likelyCauses, super.raw});
}

class ConfigValidationError extends AppError {
  ConfigValidationError(super.userMessage, {required this.problems, super.raw})
      : super(likelyCauses: problems);

  final List<String> problems;
}

class CoreBinaryMissingError extends AppError {
  CoreBinaryMissingError(String core)
      : super('$core engine is not installed',
            likelyCauses: [
              'The core binary was not found in the app directory or the path configured in Settings',
            ],
            raw: core);
}

class CoreStartError extends AppError {
  CoreStartError(super.userMessage, {required this.exitCode, this.stderrTail, super.raw})
      : super(likelyCauses: const [
          'Port already in use',
          'Invalid configuration for this core version',
          'Missing permissions for TUN mode',
        ]);

  final int? exitCode;
  final String? stderrTail;
}

class ProbeError extends AppError {
  ProbeError(super.userMessage, {this.kind, super.likelyCauses, super.raw});

  final String? kind; // dns | tcp | tls | http | proxy
}

class SubscriptionFetchError extends AppError {
  SubscriptionFetchError(super.userMessage, {required this.statusCode, super.raw});

  final int? statusCode;
}

class VaultError extends AppError {
  VaultError(super.userMessage, {super.raw});
}

class ChainError extends AppError {
  ChainError(super.userMessage, {required this.reasons, super.raw})
      : super(likelyCauses: reasons);

  final List<String> reasons;
}
