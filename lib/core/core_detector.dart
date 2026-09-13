import '../domain/entities/proxy_profile.dart';

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
  CoreDecision resolve(ProxyProfile p) {
    final decision = detect(p);
    if (p.userPinnedCore != null && p.userPinnedCore != CoreKind.unknown) {
      return CoreDecision(
        core: p.userPinnedCore!,
        confidence: 1.0,
        reasons: [...decision.reasons, 'User pinned this engine'],
      );
    }
    return decision;
  }
}
