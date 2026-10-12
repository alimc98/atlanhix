/// v0.6.12 §windows-tun — WHAT the desktop tunnel should be, decided from
/// pure inputs so the rule is unit-testable instead of buried in the connect
/// flow.
///
/// The Windows story this encodes (verified on the dev box):
///  * the Settings toggle is `proxyMode == false` → "TUN" (true = "Proxy");
///  * TUN is only *available* when the process is elevated — a non-elevated
///    sing-box 1.14.0 dies with
///    `start inbound/tun[tun-in]: configure tun interface: Access is denied.`
///    and no `wintun.dll` ships in the upstream archive (CI bundles it);
///  * when TUN is wanted but unavailable the app must NOT fail the connect:
///    it falls back to the system-proxy mode that already works and tells
///    the user the honest reason (plus a relaunch-as-administrator path).
///
/// [TunnelMode.tun] therefore means "the front config really carries a tun
/// inbound"; [TunnelMode.systemProxy] means "mixed port + OS proxy", which is
/// what Windows has been doing all along.
library;

enum TunnelMode { off, systemProxy, tun, managed }

class TunnelModeDecision {
  const TunnelModeDecision({required this.mode, required this.needsAdminNotice});

  final TunnelMode mode;

  /// True when the user asked for TUN, the platform supports it, and only
  /// Administrator rights are missing — the UI shows the "restart as
  /// administrator" dialog for this and nothing else.
  final bool needsAdminNotice;

  bool get usingTun => mode == TunnelMode.tun;
}

/// [proxyModeSelected] — Settings → Tunnel mode == Proxy.
/// [tunAvailable] — the front runtime was built with a TUN capable core
///   (on Windows: `CoreManager.enableTun`, which bootstrap only sets when
///   the process is elevated).
/// [tunSupported] — the platform ships TUN at all (Windows today; Android
///   reaches this code path only through VpnSession, which sets the mode
///   itself).
TunnelModeDecision resolveTunnelMode({
  required bool proxyModeSelected,
  required bool tunAvailable,
  required bool tunSupported,
}) {
  if (proxyModeSelected) {
    return const TunnelModeDecision(
        mode: TunnelMode.systemProxy, needsAdminNotice: false);
  }
  // TUN selected.
  if (tunSupported && tunAvailable) {
    return const TunnelModeDecision(
        mode: TunnelMode.tun, needsAdminNotice: false);
  }
  return TunnelModeDecision(
    // Fall back to the behaviour Windows already ships: the mixed inbound
    // plus the OS proxy. Failing the connect here would turn a working
    // setup into a broken one for every non-elevated user.
    mode: TunnelMode.systemProxy,
    // Only Windows can honestly promise "run as administrator and TUN will
    // work" — elsewhere the toggle is simply ahead of the platform support
    // and there is nothing for the user to DO about it.
    needsAdminNotice: tunSupported,
  );
}
