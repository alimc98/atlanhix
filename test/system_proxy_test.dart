import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/platform/system_proxy.dart';

/// v0.3.0 — W8 resolution: SystemProxyController must use proper argv lists
/// (no quoted-string splitting) and expose registry state via query().
///
/// The round-trip below runs REAL reg.exe operations against the CURRENT
/// user hive and restores the previous state afterwards. Gated on Windows.
void main() {
  test('W8: query() reads real WinINET proxy state; argv round-trip restores',
      () async {
    if (!Platform.isWindows) return;
    final before = await SystemProxyController.instance.query();
    expect(before.containsKey('ProxyEnable'), isTrue,
        reason: 'query must observe the ProxyEnable value (present or null)');

    final prevEnable = before['ProxyEnable'];
    final prevServer = before['ProxyServer'];
    final prevOverride = before['ProxyOverride'];
    try {
      await SystemProxyController.instance.enable(port: 45454);
      final during = await SystemProxyController.instance.query();
      expect(during['ProxyEnable'], '0x1',
          reason: 'system proxy must actually be ON after enable()');
      expect(during['ProxyServer'], '127.0.0.1:45454',
          reason: 'argv quoting must not corrupt the host:port value');
      expect(during['ProxyOverride'], contains('localhost'));
    } finally {
      await SystemProxyController.instance.disable();
    }
    final after = await SystemProxyController.instance.query();
    expect(after['ProxyEnable'], prevEnable ?? isNot('0x1'),
        reason: 'previous ProxyEnable must be restored (or left off)');
    if (prevServer != null) {
      expect(after['ProxyServer'], prevServer,
          reason: 'previous ProxyServer must be restored verbatim');
    }
    if (prevOverride != null) {
      expect(after['ProxyOverride'], prevOverride);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
