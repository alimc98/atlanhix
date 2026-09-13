import 'dart:async';

enum LogLevel { trace, debug, info, warn, error }

class LogLine {
  LogLine({
    required this.at,
    required this.level,
    required this.scope,
    required this.message,
  });

  final DateTime at;
  final LogLevel level;
  final String scope;
  final String message;
}

/// Structured, redacting logger (§42). Secrets are masked *before* any line
/// is stored or emitted — components cannot accidentally log credentials.
class Logger {
  Logger._();
  static final Logger instance = Logger._();

  final _controller = StreamController<LogLine>.broadcast();
  final List<LogLine> _buffer = [];
  static const _maxBuffer = 2000;

  LogLevel minLevel = LogLevel.info;
  bool privacyMode = false;

  Stream<LogLine> get stream => _controller.stream;
  List<LogLine> get buffer => List.unmodifiable(_buffer);

  static final _secretPatterns = <RegExp>[
    // vmess/vless/trojan userinfo & uuids
    RegExp(r'(?<=://)[^:@/\s]+:[^@/\s]+@'),
    // uuid-shaped ids
    RegExp(
        r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'),
    // credential-like query params
    RegExp(r'\b(?:password|pass|secret|token|key)=[^\s&;]+'),
    // wireguard private keys (no inline flags: Dart RegExp is ECMAScript)
    RegExp(r'[Pp]rivate[Kk]ey\s*=\s*\S+'),
    // subscription urls with tokens
    RegExp(r'https?://[^\s]+/(sub|api/v1/client/subscribe)[^\s]*'),
  ];

  static String redact(String message) {
    var m = message;
    for (final p in _secretPatterns) {
      m = m.replaceAllMapped(p, (match) {
        final g = match.group(0)!;
        if (g.length <= 6) return '***';
        return '${g.substring(0, 3)}***${g.substring(g.length - 2)}';
      });
    }
    return m;
  }

  void log(LogLevel level, String scope, String message) {
    if (level.index < minLevel.index) return;
    if (privacyMode && level.index < LogLevel.warn.index) return;
    final line = LogLine(
      at: DateTime.now(),
      level: level,
      scope: scope,
      message: redact(message),
    );
    _buffer.add(line);
    if (_buffer.length > _maxBuffer) _buffer.removeAt(0);
    if (!_controller.isClosed) _controller.add(line);
    // Device E2E observability (debug builds only): mirror to logcat so the
    // Dart pipeline stages are reconstructable alongside native ATX traces.
    assert(() {
      // ignore: avoid_print
      print('ATX-DART [$scope] ${line.message}');
      return true;
    }());
  }

  void trace(String scope, String msg) => log(LogLevel.trace, scope, msg);
  void debug(String scope, String msg) => log(LogLevel.debug, scope, msg);
  void info(String scope, String msg) => log(LogLevel.info, scope, msg);
  void warn(String scope, String msg) => log(LogLevel.warn, scope, msg);
  void error(String scope, String msg) => log(LogLevel.error, scope, msg);

  void clear() => _buffer.clear();

  void dispose() => _controller.close();
}
