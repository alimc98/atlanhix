import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logger.dart';

/// A supervised OS process: start/stop(graceful)/streams/exit-watch.
///
/// Async by construction — the UI isolate never blocks on process I/O.
class ManagedProcess {
  ManagedProcess._(
    this._process, {
    required this.pid,
    required this.commandLine,
  }) {
    _exitFuture = _process.exitCode.then((code) {
      exitCode = code;
      Logger.instance
          .info('process', 'exit pid=$pid code=$code cmd=$commandLine');
      _exitCompleter.complete(code);
      return code;
    });
  }

  final Process _process;
  final int pid;
  final String commandLine;
  late final Future<int> _exitFuture;
  final _exitCompleter = Completer<int>();

  int? exitCode;
  bool get isRunning => !_exitCompleter.isCompleted;

  final _stdoutCtrl = StreamController<String>.broadcast();
  final _stderrCtrl = StreamController<String>.broadcast();

  Stream<String> get stdoutStream => _stdoutCtrl.stream;
  Stream<String> get stderrStream => _stderrCtrl.stream;
  Future<int> get onExit => _exitCompleter.future;

  static Future<ManagedProcess> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    final sw = Stopwatch()..start();
    final p = await Process.start(executable, args,
        workingDirectory: workingDirectory);
    sw.stop();
    final mp = ManagedProcess._(p,
        pid: p.pid, commandLine: '$executable ${args.join(' ')}');
    Logger.instance.info(
        'process', 'started pid=${p.pid} in ${sw.elapsedMilliseconds}ms');
    p.stdout
        .transform(utf8.decoder)
        .listen(mp._stdoutCtrl.add, onError: (Object e) {
      Logger.instance.warn('process', 'stdout error pid=${p.pid}: $e');
    });
    p.stderr
        .transform(utf8.decoder)
        .listen(mp._stderrCtrl.add, onError: (Object e) {
      Logger.instance.warn('process', 'stderr error pid=${p.pid}: $e');
    });
    return mp;
  }

  /// Graceful stop: SIGTERM on POSIX; on Windows the engine binaries handle
  /// CTRL_BREAK poorly in practice, so we escalate to taskkill /T /F after a
  /// short grace window. Always returns once the process is gone.
  Future<void> stop({Duration grace = const Duration(milliseconds: 800)}) async {
    if (!isRunning) return;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      } else {
        _process.kill(ProcessSignal.sigterm);
      }
    } catch (e) {
      Logger.instance.warn('process', 'stop($pid) primary failed: $e');
    }
    final race = await Future.any([
      _exitCompleter.future.then<bool>((_) => true),
      Future<bool>.delayed(grace, () => false),
    ]);
    if (!race && isRunning) {
      try {
        if (!Platform.isWindows) _process.kill(ProcessSignal.sigkill);
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        }
      } catch (_) {}
    }
    await _exitCompleter.future
        .timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }
}

/// Allocates free loopback ports (Phase 1 infrastructure).
class PortAllocator {
  static Future<int> freePort({int prefer = 0}) async {
    if (prefer != 0) {
      if (await _isFree(prefer)) return prefer;
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<bool> _isFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } on SocketException {
      return false;
    }
  }
}

/// Why a core process died — drives recovery policy (Phase 26).
enum CoreExitKind { clean, configError, portConflict, binaryError, unknown }

class CoreExitEvent {
  const CoreExitEvent({
    required this.kind,
    required this.exitCode,
    required this.stderrTail,
    required this.uptime,
  });

  final CoreExitKind kind;
  final int exitCode;
  final String stderrTail;
  final Duration uptime;
}

CoreExitKind classifyExit(int code, String stderrTail, Duration uptime) {
  final tail = stderrTail.toLowerCase();
  if (code == 0) return CoreExitKind.clean;
  if (uptime < const Duration(seconds: 2)) {
    if (tail.contains('address already in use') ||
        tail.contains('bind') && tail.contains('in use')) {
      return CoreExitKind.portConflict;
    }
    if (tail.contains('failed to') ||
        tail.contains('invalid') ||
        tail.contains('error') && tail.contains('config') ||
        tail.contains('decode') ||
        tail.contains('parse') ||
        tail.contains('unknown field')) {
      return CoreExitKind.configError;
    }
    if (tail.contains('access is denied') ||
        tail.contains('permission')) {
      return CoreExitKind.binaryError;
    }
  }
  return CoreExitKind.unknown;
}
