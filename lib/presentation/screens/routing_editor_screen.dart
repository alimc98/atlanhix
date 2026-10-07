import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../settings/routing_settings.dart';

/// v0.4.1 §8/§10/§19/§20 — the editable Routing screen.
/// Tabs: Mode | Domains | Networks | Advanced(custom rules).
/// Every change validates → persists → flags "applied after reconnect".
class RoutingEditorScreen extends StatefulWidget {
  const RoutingEditorScreen({
    super.key,
    required this.routingRepo,
    required this.routing,
    required this.onChanged,
  });

  final RoutingSettingsRepository routingRepo;
  final RoutingSettings routing;
  final VoidCallback onChanged;

  @override
  State<RoutingEditorScreen> createState() => _RoutingEditorScreenState();
}

class _RoutingEditorScreenState extends State<RoutingEditorScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  // v0.5.6 §leak-fix: the TabController was never disposed. This State is
  // created once per push of /routing AND lives inside the shell's
  // IndexedStack, so the controller (and its animation/ticker listeners)
  // outlived the screen.
  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    await widget.routingRepo.save(widget.routing);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Routing'),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Mode'),
              Tab(text: 'Domains'),
              Tab(text: 'Networks'),
              Tab(text: 'Advanced'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [
            _ModeTab(routing: widget.routing, onPersist: _persist),
            _DomainListTab(
              title: 'Direct domains',
              hint: 'ir.example.com or *.example.ir',
              entries: widget.routing.directDomains,
              validator: DomainRuleValidator.validate,
              normalize: DomainRuleValidator.normalize,
              onChanged: _persist,
            ),
            _DomainListTab(
              title: 'Proxy domains',
              hint: 'openai.com or *.openai.com',
              entries: widget.routing.proxyDomains,
              validator: DomainRuleValidator.validate,
              normalize: DomainRuleValidator.normalize,
              onChanged: _persist,
            ),
            _AdvancedTab(routing: widget.routing, onPersist: _persist),
          ],
        ),
      );
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({required this.routing, required this.onPersist});
  final RoutingSettings routing;
  final Future<void> Function() onPersist;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // OPT-IN master switch (default OFF). Routing rules and per-app
          // lists reach the generated config only when this is on.
          SwitchListTile(
            title: const Text('Enable routing'),
            subtitle: const Text(
                'OFF (default): no routing rules — everything goes through '
                'the selected node. ON: apply the mode and rules below.'),
            value: routing.enabled,
            onChanged: (v) async {
              routing.enabled = v;
              await onPersist();
            },
          ),
          const Divider(height: 32),
          const SectionHeader('Routing mode'),
          RadioListTile<RoutingMode>(
            title: const Text('Global'),
            subtitle: const Text(
                'All traffic through the VPN/proxy, except Direct Apps '
                'and private networks.'),
            value: RoutingMode.global,
            groupValue: routing.mode,
            onChanged: routing.enabled
                ? (m) async {
                    routing.mode = m!;
                    await onPersist();
                  }
                : null,
          ),
          RadioListTile<RoutingMode>(
            title: const Text('Rule'),
            subtitle: const Text(
                'Evaluate rules: private networks and Direct Apps → DIRECT; '
                'direct/proxy domains, CIDRs and custom rules; '
                'everything else → final outbound (default proxy).'),
            value: RoutingMode.rule,
            groupValue: routing.mode,
            onChanged: routing.enabled
                ? (m) async {
                    routing.mode = m!;
                    await onPersist();
                  }
                : null,
          ),
          const Divider(height: 32),
          const SectionHeader('Application rules'),
          ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('Direct & Proxy apps'),
            subtitle: Text(
                '${routing.directApps.length} direct · ${routing.proxyApps.length} proxy'),
            enabled: routing.enabled,
            trailing: const Icon(Icons.chevron_right),
            onTap: routing.enabled
                ? () => Navigator.of(context).pushNamed('/routing/apps')
                : null,
          ),
          const Divider(height: 32),
          const SectionHeader('Final outbound (Rule mode)'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'proxy', label: Text('PROXY')),
              ButtonSegment(value: 'direct', label: Text('DIRECT')),
            ],
            selected: {routing.finalOutbound},
            onSelectionChanged: routing.enabled
                ? (s) async {
                    routing.finalOutbound = s.first;
                    await onPersist();
                  }
                : null,
          ),
          const SizedBox(height: 24),
          const _AppliedNote(),
        ],
      );
}

class _DomainListTab extends StatefulWidget {
  _DomainListTab({
    required this.title,
    required this.hint,
    required this.entries,
    required this.validator,
    required this.normalize,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<String> entries;
  final String? Function(String) validator;
  final String Function(String) normalize;
  final Future<void> Function() onChanged;

  @override
  State<_DomainListTab> createState() => _DomainListTabState();
}

class _DomainListTabState extends State<_DomainListTab> {
  String get title => widget.title;
  String get hint => widget.hint;
  List<String> get entries => widget.entries;
  String? Function(String) get validator => widget.validator;
  String Function(String) get normalize => widget.normalize;
  Future<void> Function() get onChanged => widget.onChanged;

  // v0.5.6 §leak-fix: was a `final TextEditingController` field on a
  // STATELESS widget — a fresh controller per rebuild, structurally
  // impossible to dispose. Now one instance owned by a State.
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add(BuildContext context) {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final err = validator(raw);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid: $err')));
      return;
    }
    final v = normalize(raw);
    if (entries.contains(v)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Already in the list')));
      return;
    }
    entries.add(v);
    _controller.clear();
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(hintText: hint),
                    onSubmitted: (_) => _add(context),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('No entries'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.dns, size: 18),
                        title: Text(entries[i]),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () {
                            entries.removeAt(i);
                            onChanged();
                          },
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );
}

class _AdvancedTab extends StatelessWidget {
  const _AdvancedTab({required this.routing, required this.onPersist});
  final RoutingSettings routing;
  final Future<void> Function() onPersist;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader('Network rules (CIDR)'),
          _CidrEditor(
            title: 'Direct networks',
            entries: routing.directCidrs,
            onChanged: onPersist,
          ),
          const SizedBox(height: 16),
          _CidrEditor(
            title: 'Proxy networks',
            entries: routing.proxyCidrs,
            onChanged: onPersist,
          ),
        ],
      );
}

class _CidrEditor extends StatefulWidget {
  _CidrEditor({required this.title, required this.entries, required this.onChanged});
  final String title;
  final List<String> entries;
  final Future<void> Function() onChanged;

  @override
  State<_CidrEditor> createState() => _CidrEditorState();
}

class _CidrEditorState extends State<_CidrEditor> {
  String get title => widget.title;
  List<String> get entries => widget.entries;
  Future<void> Function() get onChanged => widget.onChanged;

  // v0.5.6 §leak-fix: this was a `final TextEditingController` field on a
  // STATELESS widget — a fresh controller on every rebuild, structurally
  // impossible to dispose. Now a single instance owned by a State.
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add(BuildContext context) {
    final raw = _controller.text.trim();
    final err = CidrValidator.validate(raw);
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Invalid CIDR: $err')));
      return;
    }
    if (!entries.contains(raw)) entries.add(raw);
    _controller.clear();
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration:
                          const InputDecoration(hintText: '10.0.0.0/8'),
                      onSubmitted: (_) => _add(context),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (var i = 0; i < entries.length; i++)
                    InputChip(
                      label: Text(entries[i]),
                      onDeleted: () {
                        entries.removeAt(i);
                        onChanged();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      );
}

class _AppliedNote extends StatelessWidget {
  const _AppliedNote();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Changes are applied on the next connection (hot-reload of the '
              'active tunnel is not supported in v0.4.x).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
}


/// Simple section header used across the routing editor tabs.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}
