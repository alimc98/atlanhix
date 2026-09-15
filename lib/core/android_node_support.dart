import '../domain/entities/proxy_profile.dart';
import 'engine_availability.dart';

/// Android runnability of a node (v0.4.x): the on-device engine is
/// sing-box (libbox) only — the Xray and AmneziaWG upstream daemons do not
/// run in-app. This is the SINGLE source of truth shared by [VpnSession]
/// (connect gating) and the UI (badges/chips), so a node the dashboard
/// marks runnable is exactly a node `connect()` will attempt.
///
/// [isRunnable] mirrors the previous private `VpnSession._androidRunnable`
/// logic verbatim — semantics unchanged, just made visible to the UI.
class AndroidNodeSupport {
  AndroidNodeSupport._();

  /// True when the Android engine (sing-box / libbox) can run this node.
  static bool isRunnable(ProxyProfile p) {
    // Capability matrix verified against sing-box 1.14 source (transport
    // enum: http/ws/quic/grpc/httpupgrade) and Xray-core, 2026-09-13:
    //   * ONLY xhttp/splithttp and mKCP are upstream-Xray-exclusive;
    //     vless+reality+xtls-rprx-vision, vmess, trojan, ss, hysteria2,
    //     tuic, anytls all run on the bundled sing-box.
    //   * An Xray DETECTION therefore must not lock a node out — Auto
    //     nodes fall through to the engine matrix below.
    //   * A USER-PINNED Xray core stays blocked honestly: Android ≥10
    //     refuses exec() of extracted binaries and Xray has no gomobile
    //     export, so there is no in-app Xray runtime (never a silent
    //     swap to another engine — the pin is the user's explicit choice).
    // xhttp / mKCP need Xray — allowed now that the Xray AAR runtime exists
    // (and the :xray process handshake reported it loaded); blocked with an
    // honest reason while the runtime is missing.
    if (p.transport == Transport.xhttp ||
        p.rawParams['type'] == 'mkcp' ||
        p.rawParams['type'] == 'kcp') {
      return XrayCoreState.instance.runtimeLoaded;
    }
    if (p.userPinnedCore == CoreKind.xray) {
      return XrayCoreState.instance.runtimeLoaded;
    }
    // AmneziaWG needs its patched WireGuard kernel/userspace fork — not
    // bundled in any engine we ship, in either state (mirrors
    // notRunnableReason so the two gates can never disagree).
    if (p.amnezia?.isNotEmpty == true || p.effectiveCore == CoreKind.amneziaWg) {
      return false;
    }
    if (p.effectiveCore == CoreKind.xray && p.userPinnedCore != null) {
      return XrayCoreState.instance.runtimeLoaded;
    }
    return switch (p.protocol) {
      ProxyProtocol.vmess ||
      ProxyProtocol.vless ||
      ProxyProtocol.trojan ||
      ProxyProtocol.shadowsocks ||
      ProxyProtocol.hysteria2 ||
      ProxyProtocol.hysteria ||
      ProxyProtocol.tuic ||
      ProxyProtocol.anytls ||
      ProxyProtocol.shadowtls ||
      ProxyProtocol.naive ||
      ProxyProtocol.socks ||
      ProxyProtocol.http =>
        true,
      ProxyProtocol.wireguard ||
      ProxyProtocol.masterDnsVpn ||
      ProxyProtocol.ssh ||
      ProxyProtocol.custom =>
        false,
    };
  }

  /// WHY a node cannot run on Android today (null = runnable). Honest,
  /// user-facing wording — used in badges, tooltips and snackbars.
  static String? notRunnableReason(ProxyProfile p) {
    // AmneziaWG first: its reason is more specific than the protocol's.
    if (p.effectiveCore == CoreKind.amneziaWg ||
        p.amnezia?.isNotEmpty == true) {
      return 'Amnezia (not bundled on Android)';
    }
    if (p.transport == Transport.xhttp || p.rawParams['type'] == 'mkcp' ||
        p.rawParams['type'] == 'kcp') {
      return XrayCoreState.instance.runtimeLoaded
          ? null
          : 'Xray-only transport · Xray core off (sing-box cannot run it)';
    }
    if (p.userPinnedCore == CoreKind.xray) {
      return XrayCoreState.instance.runtimeLoaded
          ? null
          : 'Xray core off — not available in this build';
    }
    if (!isRunnable(p)) {
      return switch (p.protocol) {
        ProxyProtocol.masterDnsVpn => 'MDVPN (desktop only)',
        _ => 'Not runnable on Android',
      };
    }
    return null;
  }

  /// The core that will run this node on Android TODAY, as a user-facing
  /// label. Runnable nodes → the libbox engine; non-runnable nodes → the
  /// honest reason they cannot be tested on this device.
  static String androidCoreLabel(ProxyProfile p) {
    final reason = notRunnableReason(p);
    if (reason != null) return reason;
    // Runnable via the Xray upstream: say so — never claim sing-box dials it.
    if (_xrayOnly(p) || p.userPinnedCore == CoreKind.xray) {
      return 'Xray (upstream process)';
    }
    return 'sing-box';
  }

  static bool _xrayOnly(ProxyProfile p) =>
      p.transport == Transport.xhttp ||
      p.rawParams['type'] == 'mkcp' ||
      p.rawParams['type'] == 'kcp';

  /// Compact badge text for tight node-card rows (full reason in tooltip).
  static String shortBadge(ProxyProfile p) {
    final reason = notRunnableReason(p);
    if (reason == null) {
      // runnable — but WHICH core actually dials it?
      if (_xrayOnly(p) || p.userPinnedCore == CoreKind.xray) return 'Xray';
      return 'sing-box';
    }
    if (reason.startsWith('Amnezia')) return 'no core · Amnezia off';
    if (reason.startsWith('Xray-only')) return 'Xray off · xhttp';
    if (reason.startsWith('Xray')) return 'Xray off';
    if (reason.startsWith('MDVPN')) return 'MDVPN · desktop only';
    return 'not on Android';
  }

  /// Human-readable engine name (chip on the dashboard hero card).
  static String coreDisplayName(CoreKind k) => switch (k) {
        CoreKind.singbox => 'sing-box',
        CoreKind.xray => 'Xray',
        CoreKind.wireguardSingbox => 'sing-box (WireGuard)',
        CoreKind.amneziaWg => 'AmneziaWG',
        CoreKind.masterDnsVpn => 'MDVPN',
        CoreKind.unknown => 'auto',
      };

  /// SINGLE-CORE GUARANTEE (connect pipeline): the only core that can
  /// execute a connection in-app is sing-box (libbox). Xray / AmneziaWG /
  /// MDVPN are separate external daemon processes that do not exist on
  /// Android — a connection must never be built across two cores. `unknown`
  /// and `wireguardSingbox` pass here; protocol-level exclusions (plain
  /// WireGuard profiles, MDVPN protocol…) are enforced by [isRunnable].
  static bool coreAllowedOnAndroid(CoreKind core) => switch (core) {
        CoreKind.singbox ||
        CoreKind.wireguardSingbox ||
        CoreKind.unknown =>
          true,
        CoreKind.xray => XrayCoreState.instance.runtimeLoaded,
        CoreKind.amneziaWg ||
        CoreKind.masterDnsVpn =>
          false,
      };

  /// WHY a node is excluded from the Android connect pipeline (null =
  /// runnable). Derived from the SAME rules as [isRunnable] so the two can
  /// never drift; stable machine-prefixed codes for logs/errors. Output is
  /// redaction-safe: protocol/transport/core names only, never endpoints
  /// or credentials.
  static String? androidExclusionReason(ProxyProfile p) {
    // AmneziaWG first: its reason is more specific than the protocol's.
    if (p.effectiveCore == CoreKind.amneziaWg ||
        p.amnezia?.isNotEmpty == true) {
      return 'amnezia_wg: AmneziaWG core (amneziawg-go daemon) is not bundled on Android';
    }
    if (p.transport == Transport.xhttp || p.rawParams['type'] == 'mkcp' ||
        p.rawParams['type'] == 'kcp') {
      return XrayCoreState.instance.runtimeLoaded
          ? null
          : 'xray_transport: ${p.transport.name} is upstream-Xray-only; the Xray runtime is not loaded';
    }
    if (p.userPinnedCore == CoreKind.xray) {
      return XrayCoreState.instance.runtimeLoaded
          ? null
          : 'xray_pinned: user pinned the Xray core, but it is not available in this build';
    }
    if (p.effectiveCore == CoreKind.masterDnsVpn ||
        p.protocol == ProxyProtocol.masterDnsVpn) {
      return 'masterdnsvpn: needs the external mdvpn-client daemon, which does not run on Android';
    }
    if (!isRunnable(p)) {
      return '${p.protocol.name}: not runnable by the on-device sing-box engine';
    }
    return null;
  }

  /// User-facing hint for a [VpnSession.lastError] connect code (null = the
  /// generic "Connection failed" wording). Kept next to the codes emitted by
  /// the connect pipeline so the mapping cannot drift from the emitter.
  static String? connectErrorHint(String? code) => switch (code) {
        'XRAY_RUNTIME_UNAVAILABLE' =>
          'This node needs the Xray core (xhttp/mKCP) — sing-box is on, '
              'Xray is off in this build',
        'XRAY_START_FAILED' =>
          'The Xray process refused to start — check the engine logs',
        'NO_RUNNABLE_NODE' =>
          'No node on this device can run yet — Xray (xhttp), AmneziaWG and '
              'MDVPN nodes need their desktop cores',
        'NODE_NOT_RUNNABLE_ON_ANDROID' ||
        'CORE_NOT_RUNNABLE_ON_ANDROID' =>
          'This node needs a core that cannot run here '
              '(Xray off / AmneziaWG / MDVPN not bundled)',
        _ => null,
      };
}
