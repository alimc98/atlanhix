import '../domain/entities/proxy_profile.dart';
import 'engine_availability.dart' show MihomoCoreState;
import '../settings/app_settings.dart' show CorePreference;

/// Which core a configuration should run on + why.
class CoreDecision {
  const CoreDecision({
    required this.core,
    required this.confidence,
    required this.reasons,
  });

  final CoreKind core;
  final double confidence; // 0..1
  final List<String> reasons;

  @override
  String toString() =>
      'core=${core.name} confidence=${confidence.toStringAsFixed(2)} '
      'reasons=${reasons.join('; ')}';
}

/// Detects the correct engine for a normalized profile by inspecting the
/// complete configuration — protocol, transport, security and parameters —
/// not just the URL scheme (spec §6).
class CoreDetector {
  CoreDecision detect(ProxyProfile p) {
    final reasons = <String>[];
    var score = 0.5;
    var core = CoreKind.singbox;

    void choose(CoreKind k, double confidence, String reason) {
      core = k;
      score = confidence;
      reasons.add(reason);
    }

    // 1) WireGuard family: inspect the actual parameters.
    if (p.wireguard != null) {
      if (p.amnezia?.isNotEmpty == true) {
        choose(CoreKind.amneziaWg, 0.99,
            'AmneziaWG obfuscation parameters detected (Jc/S1/H1…)');
      } else {
        choose(CoreKind.wireguardSingbox, 0.95,
            'Native WireGuard configuration');
      }
      return CoreDecision(core: core, confidence: score, reasons: reasons);
    }

    // 2) Protocol families that only one engine can run.
    switch (p.protocol) {
      case ProxyProtocol.hysteria2:
      case ProxyProtocol.hysteria:
      case ProxyProtocol.tuic:
      case ProxyProtocol.anytls:
      case ProxyProtocol.shadowtls:
      case ProxyProtocol.naive:
      case ProxyProtocol.ssh:
        choose(CoreKind.singbox, 0.98,
            '${p.protocol.name} is supported by sing-box only');
        return CoreDecision(core: core, confidence: score, reasons: reasons);
      case ProxyProtocol.masterDnsVpn:
        choose(CoreKind.masterDnsVpn, 0.99,
            'MasterDNSVPN transport requires the external mdvpn engine');
        return CoreDecision(core: core, confidence: score, reasons: reasons);
      case ProxyProtocol.stormDns:
        // v0.6.4 §stormdns: DNS tunnels can never ride sing-box/mihomo —
        // the wire format lives only in the StormDNS client daemon.
        choose(CoreKind.stormDns, 0.99,
            'StormDNS transport requires the external StormDNS engine');
        return CoreDecision(core: core, confidence: score, reasons: reasons);
      case ProxyProtocol.custom:
        choose(CoreKind.singbox, 0.4,
            'Custom payload — engine inferred from origin format');
        return CoreDecision(core: core, confidence: score, reasons: reasons);
      default:
        break;
    }

    // 3) VMess/VLESS/Trojan/SS — decide via transport & security signals.
    var xraySignals = 0;
    var singboxSignals = 0;

    // ENGINE CAPABILITY MATRIX (verified against sing-box 1.14 source and
    // Xray-core trees, 2026-09-13): sing-box natively runs vless/vmess/
    // trojan/shadowsocks INCLUDING security=reality and flow=xtls-rprx-*.
    // The ONLY upstream-Xray-exclusive transports in our protocol set are
    // xhttp/splithttp and mKCP. Reality or flow must NOT steer a node to
    // Xray — doing so locked working vless+reality nodes out of Android
    // (device bug: 6 subscription nodes badged "Xray desktop only" and
    // were skipped, while sing-box could run every one of them).
    // Post-quantum VLESS ('mlkem768x25519plus…' encryption) is Xray-only:
    // sing-box 1.14 has no `encryption` outbound field at all (audited vs
    // bundled engine 2026-09-15) — it would silently negotiate 'none'.
    final enc = (p.encryption ?? p.rawParams['encryption'] ?? '');
    if (enc.contains('mlkem') || enc.contains('mldsa')) {
      reasons.add('post-quantum encryption (Xray-only)');
      return CoreDecision(core: CoreKind.xray, confidence: 1.0,
          reasons: reasons);
    }
    if (p.transport == Transport.xhttp) {
      xraySignals += 3;
      reasons.add('XHTTP transport is an Xray-specific transport');
      // Xray-only mode params on xhttp add confidence, nothing else does.
      if (p.rawParams['mode'] != null) xraySignals += 1;
    }
    if (p.rawParams['type'] == 'mkcp' || p.rawParams['type'] == 'kcp') {
      xraySignals += 3;
      reasons.add('mKCP transport is Xray-only');
    }
    if (p.flow != null && p.flow!.isNotEmpty) {
      singboxSignals += 1;
      reasons.add('XTLS flow ${p.flow} — supported by both engines, '
          'sing-box runs it natively');
    }
    if (p.security == Security.reality) {
      singboxSignals += 1;
      reasons.add('Reality detected — implemented by sing-box too');
    }
    if (p.rawParams['host'] != null && p.transport == Transport.ws) {
      singboxSignals += 1;
    }
    if (p.rawParams['path'] != null && p.transport == Transport.ws) {
      singboxSignals += 1;
    }

    if (p.protocol == ProxyProtocol.vmess && (p.alterId ?? 0) > 0) {
      singboxSignals += 1;
      reasons.add('Classic VMess (alterId>0) runs well on both cores');
    }

    if (xraySignals > singboxSignals) {
      core = CoreKind.xray;
      score = (0.62 + 0.1 * xraySignals).clamp(0.62, 0.99);
      if (reasons.isEmpty) reasons.add('Xray-preferring parameter combination');
    } else if (singboxSignals > xraySignals) {
      core = CoreKind.singbox;
      score = 0.72;
      reasons.add('Plain transport/security handled natively by sing-box');
    } else {
      core = CoreKind.singbox;
      score = 0.62;
      reasons.add(
          'No engine-exclusive signals — sing-box chosen as default runtime');
    }
    return CoreDecision(core: core, confidence: score, reasons: reasons);
  }

  /// Applies (and stores) user override when present.
  ///
  /// v0.5.3 §mihomo: the APP-LEVEL engine preference (Settings → Engine,
  /// [CorePreference]) participates in the resolution: `mihomo` steers the
  /// mihomo-runnable nodes (vless/vmess/trojan/ss + any transport mihomo
  /// speaks — xhttp/XMUX included) to the standalone engine; `xray` keeps
  /// the pre-0.5.3 behavior; `auto` stays the capability-matrix decision.
  /// The per-node pin (userPinnedCore) still wins over BOTH.
  CoreDecision resolve(ProxyProfile p, {CorePreference preference = CorePreference.auto}) {
    final decision = detect(p);
    if (p.userPinnedCore != null && p.userPinnedCore != CoreKind.unknown) {
      return CoreDecision(
        core: p.userPinnedCore!,
        confidence: 1.0,
        reasons: [...decision.reasons, 'User pinned this engine'],
      );
    }
    // v0.6.7 §sub-engine (user request: «ساب معمولی بزاریم هسته mihomo باشه
    // کانفیگ وصل نمیشه، ولی ساب کلش وصل میشه»): the clash importer tags its
    // profiles (metadata['origin'] = 'clash'), and Clash payloads are the
    // format mihomo executes NATIVELY — so a Clash-origin node follows the
    // engine preference WITHOUT the runtime gate that broke plain
    // subscriptions (their provider configs were never exercised against
    // the mihomo binary on Android). A clash-tagged node steered here also
    // skips the androidAvailability gate at the call sites below: when the
    // runtime is missing the callers already fall back per-node.
    if (preference == CorePreference.auto &&
        p.metadata['origin'] == 'clash' &&
        _mihomoRunnable(p)) {
      return CoreDecision(
        core: CoreKind.mihomo,
        confidence: 0.9,
        reasons: [
          ...decision.reasons,
          'Clash-origin subscription → mihomo engine (native Clash.Meta runtime)',
        ],
      );
    }
    if (preference == CorePreference.mihomo && _mihomoRunnable(p)) {
      // v0.6.5 §fix (user report: «انجین mihomo هست، کانفیگ‌ها وصل نمیشن
      // ولی عوض می‌کنیم وصل می‌شن»): the preference must only steer when the
      // mihomo runtime was actually PROBED on this device. On Android — and
      // on any desktop without the binary — `runtimeLoaded` is false, and
      // steering to mihomo made EVERY connect die with binary-missing while
      // the very same configs connected the moment the user changed the
      // engine. Fall back to the capability decision instead; the reason
      // trail records why, so the UI/logs stay honest.
      if (MihomoCoreState.instance.runtimeLoaded) {
        return CoreDecision(
          core: CoreKind.mihomo,
          confidence: 0.95,
          reasons: [
            ...decision.reasons,
            'Engine preference: mihomo (full xhttp/XMUX support)',
          ],
        );
      }
      // v0.6.7 §sub-engine: a Clash-ORIGIN node is trusted to steer even on
      // a device whose mihomo probe has not completed yet — the subscription
      // content itself is Clash.Meta (what mihomo runs natively). Callers
      // (VpnSession/ConnectionController) fall back per-node when the child
      // process still fails to boot.
      if (p.metadata['origin'] == 'clash') {
        return CoreDecision(
          core: CoreKind.mihomo,
          confidence: 0.9,
          reasons: [
            ...decision.reasons,
            'Engine preference mihomo + Clash-origin subscription → mihomo '
                '(runtime probe incomplete; callers fall back if the child '
                'fails to boot)',
          ],
        );
      }
      return CoreDecision(
        core: decision.core,
        confidence: decision.confidence,
        reasons: [
          ...decision.reasons,
          'Engine preference mihomo ignored: the mihomo binary is not '
              'available on this device — fell back to ${decision.core.name}',
        ],
      );
    }
    return decision;
  }

  /// Protocols the mihomo engine executes (v0.5.3): the classic four plus
  /// anytls/shadowtls; everything else (wireguard/mhvpn/ssh…) stays on the
  /// stock paths. Transport is NOT a restriction — xhttp/XMUX is exactly
  /// why this engine was added.
  static bool _mihomoRunnable(ProxyProfile p) => switch (p.protocol) {
        ProxyProtocol.vless ||
        ProxyProtocol.vmess ||
        ProxyProtocol.trojan ||
        ProxyProtocol.shadowsocks ||
        ProxyProtocol.anytls ||
        ProxyProtocol.shadowtls =>
          true,
        _ => false,
      };
}
