import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/platform/core_sweep.dart';

/// v0.6.3 §notify-fix — "برنامه بسته هم باشه باز توي نوتيفيكشن بار Atlanhix core
/// مياد": the `:xray` / `:mihomo` child cores are their own foreground
/// services with their own notification. The VPN service now stops them on
/// every teardown path; this sweep covers the remaining case — an app that was
/// FORCE-killed while a child ran, so nobody was left to ask it to stop.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String nativeState;
  late bool mihomoRunning;
  late bool xrayRunning;
  late List<String> childCalls;

  void mockChannels() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.atlanhix/vpn'), (call) async {
      if (call.method == 'state') return jsonEncode({'state': nativeState});
      return jsonEncode({'ok': true});
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.atlanhix/mihomo'), (call) async {
      childCalls.add('mihomo:${call.method}');
      if (call.method == 'status') {
        return jsonEncode(
            {'available': true, 'running': mihomoRunning, 'mixedPort': 2081});
      }
      if (call.method == 'stop') mihomoRunning = false;
      return jsonEncode({'ok': true});
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.atlanhix/xray'), (call) async {
      childCalls.add('xray:${call.method}');
      if (call.method == 'status') {
        return jsonEncode(
            {'available': true, 'running': xrayRunning, 'socksPort': 40820});
      }
      if (call.method == 'stop') xrayRunning = false;
      return jsonEncode({'ok': true});
    });
  }

  setUp(() {
    nativeState = 'STOPPED';
    mihomoRunning = true;
    xrayRunning = true;
    childCalls = [];
    mockChannels();
  });

  test('no live session → orphaned child cores are stopped', () async {
    await sweepOrphanedCores();
    expect(childCalls, contains('mihomo:stop'),
        reason: 'the stranded :mihomo process (and its "Atlanhix core" '
            'notification) must be torn down at boot');
    expect(childCalls, contains('xray:stop'));
  });

  test('a LIVE session keeps its children', () async {
    for (final live in [
      'CONNECTED',
      'VALIDATING',
      'STARTING',
      'PREPARING',
      'RECONNECTING',
    ]) {
      childCalls = [];
      nativeState = live;
      mihomoRunning = true;
      xrayRunning = true;
      await sweepOrphanedCores();
      expect(childCalls.where((c) => c.endsWith(':stop')), isEmpty,
          reason: '$live owns its child cores — the sweep must never touch '
              'a session the user is in');
    }
  });

  test('idle children are left alone (no pointless service churn)', () async {
    mihomoRunning = false;
    xrayRunning = false;
    await sweepOrphanedCores();
    expect(childCalls.where((c) => c.endsWith(':stop')), isEmpty);
  });
}
