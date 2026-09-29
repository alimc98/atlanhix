import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// v0.5.2 §user — LIVE MONITOR data source: battery percent, battery
/// temperature, THIS app's CPU share and RAM footprint.
///
/// One platform-channel call per poll (the native handler answers in
/// ~200 ms — it samples /proc/self/stat over a short window for the CPU
/// share). Every field is nullable: a desktop or a vendor that refuses a
/// reading shows '—' in the UI instead of a lie.
class DeviceStats {
  DeviceStats();

  static const _channel = MethodChannel('dev.atlanhix/vpn');

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// One real sample. Never throws.
  Future<DeviceSample?> poll() async {
    if (!isAndroid) return null;
    try {
      final r = await _channel
          .invokeMethod<String>('deviceStats')
          .timeout(const Duration(seconds: 4));
      if (r == null) return null;
      // The channel answers a JSON string (same convention as `state`).
      final decoded = jsonDecode(r);
      if (decoded is! Map) return null;
      final j = decoded.cast<String, dynamic>();
      return DeviceSample(
        batteryPct: j['batteryPct'] as int?,
        batteryTempC: (j['batteryTemp'] as num?)?.toDouble(),
        charging: j['charging'] as bool?,
        cpuPct: (j['cpuPct'] as num?)?.toDouble(),
        ramBytes: j['ramBytes'] as int?,
      );
    } on Exception catch (_) {
      return null; // desktop / channel hiccup — the UI shows '—'
    }
  }
}

class DeviceSample {
  const DeviceSample({
    this.batteryPct,
    this.batteryTempC,
    this.charging,
    this.cpuPct,
    this.ramBytes,
  });

  final int? batteryPct;
  final double? batteryTempC;
  final bool? charging;
  final double? cpuPct;
  final int? ramBytes;
}
