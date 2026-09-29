import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logger.dart';

/// Which engine binary is being managed.
enum CoreBinaryKind { singbox, xray, amneziaWg, masterDnsVpn }

/// Lifecycle-independent info about one engine binary on this machine.
class CoreBinaryInfo {
  const CoreBinaryInfo({
    required this.kind,
    required this.status,
    this.path,
    this.version,
    this.arch,
  });

  final CoreBinaryKind kind;

  /// `available` — executable found and version parsed.
  /// `notInstalled` — not found in any search location.
  /// `incompatible` — found but not executable / version parse failed.
  final String status; // available | notInstalled | incompatible
  final String? path;
  final String? version;
  final String? arch;
}

/// Locates, versions and validates engine binaries (Phase 2).
///
/// Search order:
///   1. explicit user-configured directory (Settings → Cores)
///   2. `<app-dir>/cores/<platform>-<arch>/`   (e.g. cores/windows-x64)
///   3. PATH lookup
///
/// NEXUS never downloads binaries on its own; see BUILD.md for official
/// sources per engine (respecting upstream licenses).
class BinaryManager {
  BinaryManager({this.userCoresDir, Directory? appDir})
      : _appCoresDir = appDir;

  final String? userCoresDir;
  Directory? _appCoresDir;

  /// App dir can be provided late (e.g. after path_provider resolves).
  set appCoresDir(Directory dir) => _appCoresDir = dir;

  static String platformDirName() {
    final os = Platform.operatingSystem; // windows | linux | macos | android
    final arch = _archName();
    return '$os-$arch';
  }

  static String _archName() {
    // Dart VM reports host arch; on Android this is the device ABI family.
    final v = Platform.version.toLowerCase();
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    if (v.contains('arm')) return 'armv7';
    return 'x64';
  }

  static String binaryName(CoreBinaryKind kind) {
    final exe = Platform.isWindows ? '.exe' : '';
    return switch (kind) {
      CoreBinaryKind.singbox => 'sing-box$exe',
      CoreBinaryKind.xray => 'xray$exe',
      CoreBinaryKind.amneziaWg => Platform.isWindows
          ? 'amneziawg$exe'
          : 'amneziawg-go',
      // v0.3.1: upstream releases name the client `masterdnsvpn-client`
      // (cmd/client in the MasterDnsVPN repo). `mdvpn-client` remains a
      // legacy fallback candidate.
      CoreBinaryKind.masterDnsVpn => Platform.isWindows
          ? 'masterdnsvpn-client$exe'
          : 'masterdnsvpn-client',
    };
  }

  /// Alternative file names accepted per engine (first hit wins).
  static List<String> binaryAliases(CoreBinaryKind kind) => switch (kind) {
        CoreBinaryKind.masterDnsVpn => Platform.isWindows
            ? ['mdvpn-client.exe']
            : ['mdvpn-client'],
        _ => const [],
      };

  /// Version-probe arguments per engine.
  static List<String> versionArgs(CoreBinaryKind kind) => switch (kind) {
        CoreBinaryKind.singbox => const ['version'],
        CoreBinaryKind.xray => const ['version'],
        CoreBinaryKind.amneziaWg => const ['--version'],
        CoreBinaryKind.masterDnsVpn => const ['-version'],
      };

  /// Candidate absolute paths for one engine, in priority order.
  ///
  /// v0.5.2 §windows-fix: a candidate whose FILE exists must never be
  /// shadowed by an earlier registered-but-stale dir — but that was already
  /// the contract (first existing file wins). What WAS broken: nothing ever
  /// told the manager the engines landed somewhere else after bootstrap.
  /// [updateAppDir] now lets the bootstrap's smarter resolver (or the
  /// Settings → Cores screen) re-point the search WITHOUT rebuilding the
  /// object graph — runtimes re-inspect on their next start anyway.
  List<String> candidatePaths(CoreBinaryKind kind) {
    final out = <String>[];
    for (final name in [binaryName(kind), ...binaryAliases(kind)]) {
      if (userCoresDir != null && userCoresDir!.isNotEmpty) {
        out.add('${userCoresDir!}${Platform.pathSeparator}$name');
      }
      final appDir = _appCoresDir;
      if (appDir != null) {
        out.add('${appDir.path}${Platform.pathSeparator}$name');
      }
      // Repo-relative development location (cores/<platform>-<arch>/).
      try {
        final cwd = Directory.current.path;
        out.add(
            '$cwd${Platform.pathSeparator}cores${Platform.pathSeparator}'
            '${platformDirName()}${Platform.pathSeparator}$name');
      } catch (_) {}
    }
    return out;
  }

  /// v0.5.2 §windows-fix: re-point the app-bundle search dir at runtime
  /// (bootstrap re-resolution / Settings → Cores override). The next
  /// [inspect] sees it — runtimes re-inspect on every start when their
  /// binary is missing.
  set appCoresDirOverride(Directory dir) => _appCoresDir = dir;

  Future<CoreBinaryInfo> inspect(CoreBinaryKind kind) async {
    final candidates = candidatePaths(kind);
    for (final path in candidates) {
      final f = File(path);
      if (!f.existsSync()) continue;
      try {
        final result = await Process.run(
          path,
          versionArgs(kind),
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 10));
        final out = '${result.stdout}\n${result.stderr}';
        final version = _extractVersion(kind, out);
        if (version == null) {
          Logger.instance.warn('binary',
              '[ATX-DART] CORE_BINARY ${kind.name} at $path answered but its '
              'version is unparsable → incompatible');
          return CoreBinaryInfo(
              kind: kind, status: 'incompatible', path: path);
        }
        return CoreBinaryInfo(
          kind: kind,
          status: 'available',
          path: path,
          version: version,
          arch: platformDirName(),
        );
      } catch (e) {
        Logger.instance.warn(
            'binary', '${kind.name} at $path is not executable: $e');
        return CoreBinaryInfo(
            kind: kind, status: 'incompatible', path: path);
      }
    }
    // v0.5.2 §windows-fix: a MISS is worth one line with the full search
    // story — "مسیر اشتباه" is diagnosable from the log alone now.
    Logger.instance.info('binary',
        '[ATX-DART] CORE_BINARY ${kind.name} NOT FOUND in '
        '${candidates.length} candidate path(s): ${candidates.take(4).join(' | ')}');
    return CoreBinaryInfo(kind: kind, status: 'notInstalled');
  }

  Future<Map<CoreBinaryKind, CoreBinaryInfo>> inspectAll() async => {
        for (final k in CoreBinaryKind.values) k: await inspect(k),
      };

  static String? _extractVersion(CoreBinaryKind kind, String out) {
    final m = switch (kind) {
      CoreBinaryKind.singbox =>
        RegExp(r'version\s+(\d+\.\d+(?:\.\d+)?)').firstMatch(out),
      CoreBinaryKind.xray =>
        RegExp(r'Xray\s+(\d+\.\d+(?:\.\d+)?)').firstMatch(out),
      // MasterDnsVPN prints "MasterDnsVPN Client Version: v2026.06.13..."
      // and may use date-based versions — accept dotted + date-based tags.
      CoreBinaryKind.masterDnsVpn => RegExp(
              r'Version:\s*(v?\d+\.\d+(?:\.\d+)?|v?\d{4}\.\d{2}\.\d{2}[^ ]*)')
          .firstMatch(out),
      _ => RegExp(r'(\d+\.\d+(?:\.\d+)?)').firstMatch(out),
    };
    return m?.group(1);
  }
}
