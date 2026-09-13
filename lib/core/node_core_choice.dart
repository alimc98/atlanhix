import '../domain/entities/proxy_profile.dart';

/// Per-node core chooser (v0.4.1 § user request): every node card can pin
/// its runtime to one of three honest choices:
///
///   * **Auto** (`CoreKind.unknown`) — CoreDetector classifies the node and
///     the app picks the best engine for it. This is the DEFAULT.
///   * **sing-box** — the node must run through sing-box. On Android this is
///     the only in-app engine; on desktop it forces the libbox/sing-box path.
///   * **Xray** — the node must run through Xray. HONEST PLATFORM FACT
///     (device-research 2026-09-13): Android ≥10 refuses to exec() binaries
///     extracted at runtime (W^X), and Xray-core ships no gomobile/mobile
///     export — so an in-app Xray daemon cannot run on this Mi 9T. Desktop
///     (Windows/Linux/macOS) DOES run Xray as its own process, so the pin
///     works there. Choosing Xray on Android is allowed (persisted) but the
///     connect attempt fails fast with CORE_NOT_RUNNABLE_ON_ANDROID and the
///     error hint explains why — never a silent auto-swap to sing-box.
///
/// Hysteria (v1/v2), TUIC and similar QUIC outbounds are sing-box-only
/// implementations — Xray has no hysteria support, so the picker DISABLES
/// the Xray option for them with an inline explanation (user: "hysteria روي
/// xray فکر کنم نباشه" — correct, and the UI now says so).
class NodeCoreChoice {
  NodeCoreChoice._();

  static const auto = CoreKind.unknown;
  static const singBox = CoreKind.singbox;
  static const xray = CoreKind.xray;

  /// Protocols the Xray engine cannot run at all (sing-box-only stacks).
  static const xrayUnsupportedProtocols = {
    ProxyProtocol.hysteria,
    ProxyProtocol.hysteria2,
    ProxyProtocol.tuic,
    ProxyProtocol.anytls,
    ProxyProtocol.shadowtls,
    ProxyProtocol.naive,
  };

  static bool xrayCanRun(ProxyProfile p) =>
      !xrayUnsupportedProtocols.contains(p.protocol);

  /// Label shown on the node card for the CURRENT selection.
  static String labelFor(ProxyProfile p, {required bool onAndroid}) {
    switch (p.userPinnedCore) {
      case null:
      case CoreKind.unknown:
        return 'auto';
      case CoreKind.singbox:
      case CoreKind.wireguardSingbox:
        return 'sing-box';
      case CoreKind.xray:
        return onAndroid ? 'Xray · desktop only' : 'Xray';
      case CoreKind.amneziaWg:
        return 'AmneziaWG';
      case CoreKind.masterDnsVpn:
        return 'MDVPN';
    }
  }

  /// One-line explanation for the Xray option in the picker (null = fine).
  static String? xrayWarning(ProxyProfile p, {required bool onAndroid}) {
    if (!xrayCanRun(p)) {
      return '${p.protocol.name} is a sing-box-only protocol — Xray cannot '
          'run this node on any platform.';
    }
    if (onAndroid) {
      return 'Xray cannot run inside an Android app (Android blocks '
          'exec() of downloaded binaries; Xray has no mobile library). '
          'Works on desktop.';
    }
    return null;
  }
}
