import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/scoring/node_scorer.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_compiler.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/chain/chain_planner.dart';

ProxyProfile _node(String id) => ProxyProfile(
      id: id,
      name: 'n-$id',
      server: '$id.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      uuid: 'u-$id',
    );

ProxyProfile _wgProfile(String id) => ProxyProfile(
      id: id,
      name: 'wg-$id',
      server: '5.6.7.8',
      port: 51820,
      protocol: ProxyProtocol.wireguard,
      wireguard: WireGuardConfig(
        privateKey: 'priv=',
        peerPublicKey: 'peer=',
        endpointHost: '5.6.7.8',
        endpointPort: 51820,
      ),
    );

void main() {
  group('NodeScorer', () {
    test('latency strategy prefers faster node', () {
      final scorer = NodeScorer();
      final fast = _node('fast');
      final slow = _node('slow');
      final stats = {
        fast.id: NodeHealthStats()
          ..state = NodeHealth.healthy
          ..lastLatencyMs = 40
          ..successRate = 0.95,
        slow.id: NodeHealthStats()
          ..state = NodeHealth.healthy
          ..lastLatencyMs = 900
          ..successRate = 0.9,
      };
      final ranked =
          scorer.rank([fast, slow], stats, SelectionStrategy.lowestLatency);
      expect(ranked.first.$1.id, fast.id);
    });

    test('consecutive failures penalize score', () {
      final scorer = NodeScorer();
      final p = _node('p');
      final healthy = scorer.score(
          p,
          NodeHealthStats()
            ..state = NodeHealth.healthy
            ..lastLatencyMs = 50
            ..successRate = 1,
          SelectionStrategy.smart);
      final failing = scorer.score(
          p,
          NodeHealthStats()
            ..state = NodeHealth.timeout
            ..lastLatencyMs = 50
            ..consecutiveFailures = 3,
          SelectionStrategy.smart);
      expect(healthy.total, greaterThan(failing.total));
    });
  });

  group('Routing compiler', () {
    final compiler = RoutingCompiler();

    test('compiles suffix rules for sing-box and xray', () {
      final profile = RoutingProfile(
        id: 't',
        name: 'test',
        rules: [
          RoutingRule(
            id: 'r1',
            matchType: RuleMatchType.domainSuffix,
            patterns: ['.google.com'],
            action: RoutingAction.warp,
          ),
          RoutingRule(
            id: 'r2',
            matchType: RuleMatchType.ipCidr,
            patterns: ['10.0.0.0/8'],
            action: RoutingAction.direct,
          ),
        ],
      );
      final sb = compiler.singBoxRules(profile);
      expect(sb.first['domain_suffix'], ['google.com']);
      expect(sb.first['outbound'], 'warp');
      final xr =
          compiler.xrayRules(profile, proxyTag: 'proxy', warpTag: 'warp');
      expect(xr[0]['outboundTag'], 'warp');
      expect((xr[0]['domain'] as List).first, contains('google.com'));
      expect(xr[1]['outboundTag'], 'direct');
    });

    test('sanity checker flags loopback routing', () {
      final bad = RoutingProfile(
        id: 'bad',
        name: 'bad',
        rules: [
          RoutingRule(
            id: 'x',
            matchType: RuleMatchType.domainSuffix,
            patterns: ['localhost'],
            action: RoutingAction.proxy,
          ),
        ],
      );
      expect(RouteSanityChecker.profileWouldLoop(bad), isTrue);
    });
  });

  group('ChainPlanner', () {
    final planner = ChainPlanner();

    test('proxy → warp chain is valid and ordered app-outward', () {
      final node = _node('n1');
      final warp = _wgProfile('warp')..name = 'WARP';
      final chain = ProxyChain(
        id: 'c1',
        name: 'test',
        elements: [
          ChainElement(
              id: 'e1', type: ChainElementType.profile, profileId: node.id),
          ChainElement(
              id: 'e2', type: ChainElementType.warp, profileId: warp.id),
        ],
      );
      expect(planner.validate(chain, [node, warp]).ok, isTrue);
      final plan = planner.plan(chain, [node, warp]);
      expect(plan.hops.length, 2);
      // Generation order is outermost-first: WARP dials the internet, the
      // VLESS node tunnels through it.
      expect(plan.hops.first.profile.id, warp.id);
      expect(plan.hops.first.isLast, isTrue);
      expect(plan.hops.last.profile.id, node.id);
    });

    test('wg-through-wg is rejected', () {
      final wg1 = _wgProfile('a');
      final wg2 = _wgProfile('b');
      final chain = ProxyChain(
        id: 'c2',
        name: 'bad',
        elements: [
          ChainElement(
              id: 'e1', type: ChainElementType.profile, profileId: wg1.id),
          ChainElement(
              id: 'e2', type: ChainElementType.profile, profileId: wg2.id),
        ],
      );
      final v = planner.validate(chain, [wg1, wg2]);
      expect(v.ok, isFalse);
      expect(v.reasons, anyElement(contains('UDP-in-UDP')));
    });
  });

  group('HealthStore', () {
    test('derives state from consecutive failures', () {
      final store = HealthStore();
      final t = DateTime.now();
      for (var i = 0; i < 3; i++) {
        store.record(HealthRecord(
            profileId: 'p', at: t, ok: false, errorKind: 'timeout'));
      }
      final s = store.statsOf('p')!;
      expect(s.consecutiveFailures, 3);
      expect(s.state, NodeHealth.offline);
      store.record(
          HealthRecord(profileId: 'p', at: t, ok: true, latencyMs: 42));
      expect(store.statsOf('p')!.state, NodeHealth.healthy);
      expect(store.statsOf('p')!.lastLatencyMs, 42);
    });
  });
}
