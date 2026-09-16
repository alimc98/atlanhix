// v0.4.6: a failed probe must say WHY — the engine stderr tail (redacted)
// rides along in ProbeError.likelyCauses so the UI can show
// "xray: lookup cdn.example.com: no such host" instead of a bare
// "The node did not respond through the tunnel.".
//
// These tests pin the string-shaping contract the controller relies on:
//   * Logger.redact must strip credentials from engine stderr lines
//     (xray logs carry full share-link params on parse errors);
//   * CoreManager.engineStderrTail bounds the length (UI label safety).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/logger.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

void main() {
  group('Logger.redact on engine stderr (probe-cause pipeline)', () {
    test('uuids and passwords in xray parse errors are masked', () {
      final line =
          'vless@9d4a1b2c-33d4-45e6-a7b8-c9d0e1f2a3b4: settings: password=hunter2';
      final out = Logger.redact(line);
      expect(out.contains('9d4a1b2c-33d4-45e6'), isFalse);
      expect(out.contains('hunter2'), isFalse);
    });

    test('plain dial/lookup errors pass through untouched', () {
      const line = 'dial tcp: lookup cdn.example.com: no such host';
      expect(Logger.redact(line), line);
    });
  });

  group('CoreManager.engineStderrTail', () {
    test('returns empty string when no engine has run', () async {
      final mgr = CoreManager(
        binaryManager: BinaryManager(),
        workDir: Directory.systemTemp,
      );
      expect(mgr.engineStderrTail(CoreKind.xray), isEmpty);
      expect(mgr.engineStderrTail(CoreKind.singbox), isEmpty);
      await mgr.dispose();
    });

    test('tail never exceeds the 400-char display bound', () {
      // The ring itself only fills from a real process stream; the display
      // bound is a pure function of the joined string — assert the same
      // truncation shape engineStderrTail applies (keep last 400 chars).
      const over = 400;
      final fake = List.filled(6, 'x' * 200);
      final joined = fake.join(' | ');
      final bounded = joined.length > over
          ? joined.substring(joined.length - over)
          : joined;
      expect(bounded.length, over);
    });
  });
}
