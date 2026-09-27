import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/settings/app_settings.dart';

void main() {
  test('effectiveDelayTestUrl: empty field → gstatic default', () {
    final s = AppSettings();
    expect(s.effectiveDelayTestUrl, AppSettings.defaultDelayTestUrl);
  });

  test('effectiveDelayTestUrl: an http:// URL is honored verbatim', () {
    final s = AppSettings()..delayTestUrl = 'http://www.gstatic.com/generate_204';
    expect(s.effectiveDelayTestUrl, 'http://www.gstatic.com/generate_204');
  });

  test('effectiveDelayTestUrl: whitespace-only falls back to default', () {
    final s = AppSettings()..delayTestUrl = '   ';
    expect(s.effectiveDelayTestUrl, AppSettings.defaultDelayTestUrl);
  });

  test('effectiveWarpProbeUrl: explicit warpProbeUrl wins over the shared field',
      () {
    final s = AppSettings()
      ..warpProbeUrl = 'https://warp-specific.example/ok'
      ..delayTestUrl = 'http://shared.example/204';
    expect(s.effectiveWarpProbeUrl, 'https://warp-specific.example/ok');
  });

  test('effectiveWarpProbeUrl: falls through to the shared delay-test URL', () {
    final s = AppSettings()..delayTestUrl = 'http://shared.example/204';
    expect(s.effectiveWarpProbeUrl, 'http://shared.example/204');
  });

  test('delayTestUrl survives the JSON round-trip', () {
    final s = AppSettings()..delayTestUrl = 'http://cap.example/204';
    final back = AppSettings.fromJson(s.toJson());
    expect(back.delayTestUrl, 'http://cap.example/204');
  });
}
