import 'package:flutter/foundation.dart';

/// v0.4.3: WHAT core will actually run the selected node on Android, and why
/// not. Feeds the honest engine badge: e.g. a node the Xray library core is
/// chosen for but the AAR is absent → "sing-box and Xray are off; this engine
/// is not available on this build" — never a silent fallback.
enum CoreAvailability {
  singboxReady,
  xrayReady,
  xrayMissing,
  protocolUnsupportedByAnyCore,
}

class CoreAvailabilityStatus {
  const CoreAvailabilityStatus({
    required this.android,
    required this.xrayAarLoaded,
    required this.protocol,
    required this.transport,
    required this.amnezia,
  });

  final bool android;

  /// True once the `:xray` process reports the gomobile libv2ray AAR is
  /// present and startable (MethodChannel handshake at boot).
  final bool xrayAarLoaded;
  final String protocol;
  final String transport;

  /// AmneziaWG-flavoured WireGuard — needs the forked sing-box build we do
  /// not ship.
  final bool amnezia;

  CoreAvailability get status {
    if (amnezia) return CoreAvailability.protocolUnsupportedByAnyCore;
    if (!android) {
      // Desktop always has both binaries; availability is an Android notion.
      return CoreAvailability.singboxReady;
    }
    if (xrayAarLoaded) return CoreAvailability.xrayReady;
    return CoreAvailability.singboxReady; // sing-box AAR is compiled in
  }

  /// Human label for the engine chip — truthful in every state.
  String get label => switch (status) {
        CoreAvailability.singboxReady => 'sing-box',
        CoreAvailability.xrayReady => 'sing-box + Xray',
        CoreAvailability.xrayMissing => 'sing-box',
        CoreAvailability.protocolUnsupportedByAnyCore => 'no core',
      };

  /// The "why" line shown when the user pins/needs a core that cannot run.
  String? unavailableReason(String wantedCore) {
    if (wantedCore == 'xray' &&
        !xrayAarLoaded &&
        status != CoreAvailability.protocolUnsupportedByAnyCore) {
      return 'Xray core is not in this build (sing-box is on; Xray is off)';
    }
    if (status == CoreAvailability.protocolUnsupportedByAnyCore) {
      return 'sing-box and Xray cannot run $protocol on this device — '
          'engine not available';
    }
    return null;
  }

  /// Transport classes ONLY the Xray core can dial. Used to gate Auto: when
  /// these appear and the AAR is missing, the node is honestly unrunnable.
  bool get needsXray =>
      transport == 'xhttp' || transport == 'kcp' || transport == 'mkcp';

  bool get xrayBlockedForNeed => needsXray && !xrayAarLoaded;

  @override
  String toString() =>
      'CoreAvailabilityStatus($protocol/$transport, xray=$xrayAarLoaded)';

  @override
  bool operator ==(Object o) =>
      o is CoreAvailabilityStatus &&
      o.android == android &&
      o.xrayAarLoaded == xrayAarLoaded &&
      o.protocol == protocol &&
      o.transport == transport &&
      o.amnezia == amnezia;
  @override
  int get hashCode =>
      Object.hash(android, xrayAarLoaded, protocol, transport, amnezia);
}

/// Process-wide mutable holder for the AAR handshake result — set once from
/// the Kotlin `:xray` ping at app boot; read by UI + configgen gates.
class XrayCoreState {
  XrayCoreState._();
  static final XrayCoreState instance = XrayCoreState._();

  bool _runtimeLoaded = false;
  bool get runtimeLoaded => _runtimeLoaded;

  void setRuntimeLoaded(bool v) {
    if (_runtimeLoaded == v) return;
    _runtimeLoaded = v;
    VpnRefresh.notify();
  }
}

/// Tiny event hub so screens repaint when the engine report arrives.
class VpnRefresh {
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);
  static void notify() => tick.value++;
}
