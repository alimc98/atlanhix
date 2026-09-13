import 'package:flutter/material.dart';

import '../../core/dns_catalog.dart';
import '../../core/dns_scanner.dart';
import '../../settings/app_settings.dart';

/// v0.4.1 § user request: full DNS scanner screen.
///
///   * ships the verified catalogue (domestic clean resolvers + foreign
///     control group),
///   * lets the user add ANY custom entry (`name=ip`, `ip:port`,
///     `https://…/dns-query`, `tls://host`),
///   * probes every entry REAL from this device over UDP/TCP/DoH and shows
///     latency, actual answers, and a poisoning verdict — an answer in
///     private/CGNAT space for a public hostname is flagged SINKHOLE even
///     though it technically "answered",
///   * "Apply" writes the chosen entries into AppSettings as the remote /
///     domestic DNS overrides the engine consumes on the next connect.
class DnsScanScreen extends StatefulWidget {
  const DnsScanScreen({
    super.key,
    required this.settings,
    required this.onSave,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings) onSave;

  @override
  State<DnsScanScreen> createState() => _DnsScanScreenState();
}

class _DnsScanScreenState extends State<DnsScanScreen> {
  final List<DnsProbeTarget> _targets = [
    ...DnsCatalog.domestic,
    ...DnsCatalog.international,
  ];
  final List<DnsProbeResult> _results = [];
  final TextEditingController _custom = TextEditingController();
  bool _scanning = false;
  bool _includeCustom = true;

  List<DnsProbeTarget> get _scanTargets => [
        // Manual entries join the scan only while the toggle is on —
        // an honest switch: it changes WHICH resolvers get probed.
        if (_includeCustom) ..._customTargets,
        ..._targets,
      ];

  final List<DnsProbeTarget> _customTargets = [];

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _results.clear();
    });
    final scanner = DnsScanner();
    await scanner.scan(_scanTargets, onResult: (r) {
      if (!mounted) return;
      setState(() {
        _results.add(r);
        _results.sort((a, b) {
          // reachable first, then by latency, then input order.
          final ra = a.reachable ? 0 : 1;
          final rb = b.reachable ? 0 : 1;
          if (ra != rb) return ra.compareTo(rb);
          if (ra == 0) {
            final la = a.latencyMs ?? 0;
            final lb = b.latencyMs ?? 0;
            if (la != lb) return la.compareTo(lb);
          }
          return _scanTargets.indexOf(a.target) -
              _scanTargets.indexOf(b.target);
        });
      });
    });
    if (!mounted) return;
    setState(() => _scanning = false);
  }

  void _addCustom() {
    final line = _custom.text.trim();
    if (line.isEmpty) return;
    final t = DnsCatalog.parseCustom(line);
    if (t == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Cannot parse. Use: name=1.2.3.4, 1.2.3.4:5300, '
              'https://host/dns-query or tls://host')));
      return;
    }
    setState(() {
      _custom.text = '';
      _customTargets.insert(0, t);
    });
  }

  Future<void> _apply(DnsProbeResult best) async {
    final s = widget.settings;
    // Store the entry in the exact form the engine parser understands:
    // DoH → https URL; anything else (udp or tcp probe succeeded) → plain
    // resolver address (the engine uses UDP/53; a tcp-only reachability is
    // rare — the row is still the user's informed pick).
    if (best.target.transport == DnsTransport.doh) {
      s.remoteDns =
          'https://${best.target.host}${best.target.dohPath ?? '/dns-query'}';
    } else {
      s.remoteDns = best.target.port == 53
          ? best.target.host
          : '${best.target.host}:${best.target.port}';
    }
    s.dnsMode = DnsModeUi.auto;
    await widget.onSave(s);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Remote DNS set to ${s.remoteDns} — applies on next connect'),
        duration: const Duration(seconds: 3)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS scanner'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _custom,
                    decoration: const InputDecoration(
                      labelText: 'Custom resolver (scanned too)',
                      hintText: 'name=1.2.3.4 · https://doh.example/dns-query',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addCustom(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                    onPressed: _addCustom, icon: const Icon(Icons.add)),
              ],
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Include custom entry in scans'),
            value: _includeCustom,
            onChanged: (v) => setState(() => _includeCustom = v),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Tap a row to set it as Remote DNS. Rows marked SINKHOLE '
              'answered with a private IP (carrier poisoning) — never pick '
              'those. NO ANSWER = blocked/unreachable from this network.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
          if (_results.isEmpty && !_scanning)
            const Expanded(
                child: Center(
                    child: Text('Press ▶ to scan all resolvers '
                        'from this device'))),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                final color = switch (r.verdict) {
                  DnsPoisonVerdict.clean => Colors.greenAccent,
                  DnsPoisonVerdict.sinkhole => Colors.orangeAccent,
                  DnsPoisonVerdict.unreachable => Colors.redAccent,
                };
                final icon = switch (r.verdict) {
                  DnsPoisonVerdict.clean => Icons.verified,
                  DnsPoisonVerdict.sinkhole => Icons.warning_amber,
                  DnsPoisonVerdict.unreachable => Icons.block,
                };
                return ListTile(
                  dense: true,
                  leading: Icon(icon, color: color),
                  title: Text(r.target.label),
                  subtitle: Text(
                    '${r.verdict.name.toUpperCase()}'
                    '${r.latencyMs != null ? ' · ${r.latencyMs}ms' : ''}'
                    '${r.answers.isNotEmpty ? ' · ${r.answers.join(" ")}' : ''}'
                    '${r.error != null ? ' · ${r.error}' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                  trailing: r.verdict == DnsPoisonVerdict.clean
                      ? const Icon(Icons.check_circle_outline)
                      : null,
                  onTap: r.verdict == DnsPoisonVerdict.clean
                      ? () => _apply(r)
                      : null,
                );
              },
            ),
          ),
          if (_customTargets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('custom entries: ${_customTargets.map((e) => e.name).join(", ")}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
