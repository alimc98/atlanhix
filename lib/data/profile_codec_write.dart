import '../domain/entities/proxy_profile.dart';
import 'profile_codec.dart';
import 'secure_vault.dart';
import 'app_storage.dart';

/// Serializes a profile for storage; secrets are moved into the vault and
/// replaced by references (§41).
Map<String, dynamic> profileToStorable(
    ProxyProfile p, SecureVault vault, String vaultSalt) {
  String? vaultify(String? v) {
    if (v == null || v.isEmpty) return null;
    final key = 'profile.${p.id}.$vaultSalt';
    vault.write(key, v);
    return '$vaultPrefix$key';
  }

  return {
    'id': p.id,
    'name': p.name,
    'server': p.server,
    'port': p.port,
    'protocol': p.protocol.name,
    'transport': p.transport.name,
    'security': p.security.name,
    'core': p.core.name,
    'uuid': vaultify(p.uuid),
    'password': vaultify(p.password),
    'alterId': p.alterId,
    'flow': p.flow,
    'path': p.path,
    'host': p.host,
    'serviceName': p.serviceName,
    'sni': p.sni,
    'fingerprint': p.fingerprint,
    'allowInsecure': p.allowInsecure,
    'alpn': p.alpn,
    'realityPublicKey': p.realityPublicKey,
    'realityShortId': p.realityShortId,
    'realitySpiderX': p.realitySpiderX,
    'ssMethod': p.ssMethod,
    'hysteriaObfsPassword': vaultify(p.hysteriaObfsPassword),
    'hysteriaUpMbps': p.hysteriaUpMbps,
    'hysteriaDownMbps': p.hysteriaDownMbps,
    'tuicUuid': vaultify(p.tuicUuid),
    'tuicToken': vaultify(p.tuicToken),
    if (p.wireguard != null)
      'wireguard': {
        'privateKey': vaultify(p.wireguard!.privateKey),
        'peerPublicKey': p.wireguard!.peerPublicKey,
        'endpointHost': p.wireguard!.endpointHost,
        'endpointPort': p.wireguard!.endpointPort,
        'preSharedKey': vaultify(p.wireguard!.preSharedKey),
        'allowedIps': p.wireguard!.allowedIps,
        'dns': p.wireguard!.dns,
        'addresses': p.wireguard!.addresses,
        'mtu': p.wireguard!.mtu,
        'persistentKeepalive': p.wireguard!.persistentKeepalive,
        'reserved': p.wireguard!.reserved,
      },
    if (p.amnezia != null)
      'amnezia': {
        'jc': p.amnezia!.jc,
        'jmin': p.amnezia!.jmin,
        'jmax': p.amnezia!.jmax,
        's1': p.amnezia!.s1,
        's2': p.amnezia!.s2,
        'h1': p.amnezia!.h1,
        'h2': p.amnezia!.h2,
        'h3': p.amnezia!.h3,
        'h4': p.amnezia!.h4,
      },
    'rawParams': p.rawParams,
    'raw': {
      if (p.rawConfig != null && p.rawConfig!.length < 4000)
        'text': p.rawConfig,
    },
    'source': p.source.name,
    'subscriptionId': p.subscriptionId,
    'tags': p.tags,
    'metadata': p.metadata,
    'userPinnedCore': p.userPinnedCore?.name,
    'enabled': p.enabled,
    'createdAt': p.createdAt?.toIso8601String(),
  };
}
