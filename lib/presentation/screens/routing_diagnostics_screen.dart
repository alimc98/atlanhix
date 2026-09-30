import 'package:flutter/material.dart';

import '../../application/dependencies.dart';
import '../../settings/routing_settings.dart';

/// v0.4.1 §33/§34 — Routing diagnostics + the "Test Routing" tool.
///
/// Shows the effective routing configuration (mode, final outbound, app
/// lists, DNS, IPv6, TUN/engine state) and evaluates user input against the
/// REAL compiled rules via RuntimeConfigBridge.evaluate — the same decision
/// data the engine consumes.
class RoutingDiagnosticsScreen extends StatefulWidget {
  const RoutingDiagnosticsScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<RoutingDiagnosticsScreen> createState() =>
      _RoutingDiagnosticsScreenState();
}

class _RoutingDiagnosticsScreenState extends State<RoutingDiagnosticsScreen> {
  final _input = TextEditingController();
  RoutingDecision? _decision;

  // v0.5.6 §leak-fix: this State had no dispose(), so every push of
  // /routing/diagnostics abandoned a live TextEditingController.
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    final r = d.routingSettings;
    final bridge = d.configBridge;

    return Scaffold(
      appBar: AppBar(title: const Text('Routing diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(context, 'Effective configuration', [
            _kv('Routing',
                r.enabled ? 'ENABLED (${r.mode.name.toUpperCase()})' : 'OFF (opt-in — no rules applied)'),
            _kv('Mode', r.mode.name.toUpperCase()),
            _kv('Final outbound', r.finalOutbound.toUpperCase()),
            _kv('Direct apps', '${r.directApps.length}'),
            _kv('Proxy apps', '${r.proxyApps.length}'),
            _kv('Direct domains', '${r.directDomains.length}'),
            _kv('Proxy domains', '${r.proxyDomains.length}'),
            _kv('Direct CIDRs', '${r.directCidrs.length}'),
            _kv('Proxy CIDRs', '${r.proxyCidrs.length}'),
            _kv('DNS', bridge.dnsSettings().mode.name),
            _kv('DNS servers (TUN)', bridge.tunDnsServers().join(', ')),
            _kv('IPv6', d.appSettings.ipv6.name.toUpperCase()),
            _kv('MTU', d.appSettings.mtu == 0 ? 'AUTO (8500)' : '${d.appSettings.mtu}'),
          ]),
          const SizedBox(height: 16),
          _card(context, 'Runtime state', [
            FutureBuilder<Map<String, dynamic>>(
              future: d.vpnSession.controller.diagnostics(),
              builder: (context, snap) {
                final data = snap.data ?? const {};
                return Column(
                  children: [
                    _kv('TUN', _tunLabel(data)),
                    _kv('Engine',
                        data['nativeState'] == 'VALIDATING' || data['nativeState'] == 'CONNECTED'
                            ? 'READY'
                            : 'STOPPED'),
                    _kv('Dart phase', data['phase']?.toString() ?? '-'),
                    if (data['detail'] != null) _kv('Detail', data['detail'].toString()),
                  ],
                );
              },
            ),
          ]),
          const SizedBox(height: 16),
          _card(context, 'Test routing', [
            const Text(
                'Enter a domain, IP, or package name — the decision is '
                'evaluated against the same rules the engine uses.'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      hintText: 'google.com · 192.168.1.1 · com.android.chrome',
                    ),
                    onSubmitted: (_) => _test(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _test, child: const Text('Test')),
              ],
            ),
            if (_decision != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  '${_decision!.verdict} ← ${_decision!.matchedRule}\n'
                  'outbound: ${_decision!.outbound}',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  String _tunLabel(Map<String, dynamic> data) {
    final s = data['nativeState']?.toString().toUpperCase() ?? 'UNKNOWN';
    return (s == 'VALIDATING' || s == 'CONNECTED') ? 'UP' : 'DOWN';
  }

  void _test() {
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    final bridge = widget.deps.configBridge;
    final isIp = RegExp(r'^[0-9a-fA-F.:]+$').hasMatch(raw) && raw.contains(':') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d+)?$').hasMatch(raw);
    final decision = isIp
        ? bridge.evaluate(ip: raw.split('/')[0])
        : raw.contains('.') && !raw.contains(' ')
            ? bridge.evaluate(domain: raw)
            : bridge.evaluate(appPackage: raw);
    setState(() => _decision = decision);
  }

  Widget _card(BuildContext context, String title, List<Widget> children) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 170,
                child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
