import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../theme/theme.dart';

/// v0.4.3: create a node by hand (pick a protocol, fill fields, save) AND
/// edit an existing profile in place. One form, two modes.
class NodeEditorScreen extends StatefulWidget {
  const NodeEditorScreen({super.key, required this.deps, this.profile});

  final AppDependencies deps;
  final ProxyProfile? profile;

  bool get isEdit => profile != null;

  @override
  State<NodeEditorScreen> createState() => _NodeEditorScreenState();
}

class _NodeEditorScreenState extends State<NodeEditorScreen> {
  late ProxyProtocol _protocol;
  late final TextEditingController _name;
  late final TextEditingController _server;
  late final TextEditingController _port;
  late final TextEditingController _uuid;
  late final TextEditingController _password;
  late final TextEditingController _alterId;
  late Transport _transport;
  late Security _security;
  late final TextEditingController _path;
  late final TextEditingController _host;
  late final TextEditingController _sni;
  late final TextEditingController _fp;
  late final TextEditingController _alpn;
  late final TextEditingController _flow;
  late final TextEditingController _pubKey;
  late final TextEditingController _shortId;
  late final TextEditingController _ssMethod;
  late final TextEditingController _obfs;
  late final TextEditingController _upMbps;
  late final TextEditingController _downMbps;
  bool _allowInsecure = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _protocol = p?.protocol ?? ProxyProtocol.vless;
    _transport = p?.transport ?? Transport.ws;
    _security = p?.security ?? Security.tls;
    _allowInsecure = p?.allowInsecure ?? false;
    TextEditingController tc(String? v) => TextEditingController(text: v ?? '');
    _name = tc(p?.name);
    _server = tc(p?.server);
    _port = tc(p?.port?.toString());
    _uuid = tc(p?.uuid ?? p?.tuicUuid);
    _password = tc(p?.password);
    _alterId = tc(p?.alterId?.toString() ?? '0');
    _path = tc(p?.path);
    _host = tc(p?.host);
    _sni = tc(p?.sni);
    _fp = tc(p?.fingerprint);
    _alpn = tc((p?.alpn ?? const []).join(','));
    _flow = tc(p?.flow);
    _pubKey = tc(p?.realityPublicKey);
    _shortId = tc(p?.realityShortId);
    _ssMethod = tc(p?.ssMethod);
    _obfs = tc(p?.hysteriaObfsPassword);
    _upMbps = tc(p?.hysteriaUpMbps?.toString());
    _downMbps = tc(p?.hysteriaDownMbps?.toString());
  }

  @override
  void dispose() {
    for (final c in [
      _name, _server, _port, _uuid, _password, _alterId, _path, _host, _sni,
      _fp, _alpn, _flow, _pubKey, _shortId, _ssMethod, _obfs, _upMbps, _downMbps,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _needsUuid =>
      _protocol == ProxyProtocol.vless || _protocol == ProxyProtocol.vmess;
  bool get _needsPassword =>
      _protocol == ProxyProtocol.trojan ||
      _protocol == ProxyProtocol.shadowsocks ||
      _protocol == ProxyProtocol.hysteria2 ||
      _protocol == ProxyProtocol.hysteria;
  bool get _isHysteria =>
      _protocol == ProxyProtocol.hysteria2 ||
      _protocol == ProxyProtocol.hysteria;
  bool get _isTcpFamily =>
      _protocol == ProxyProtocol.vless ||
      _protocol == ProxyProtocol.vmess ||
      _protocol == ProxyProtocol.trojan;

  Future<void> _save() async {
    final server = _server.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 443;
    if (server.isEmpty) {
      _toast('Server address required');
      return;
    }
    if (_name.text.trim().isEmpty) {
      _toast('Give the node a name');
      return;
    }
    final profile = ProxyProfile(
      id: widget.profile?.id ?? Ids.newId(),
      name: _name.text.trim(),
      server: server,
      port: port,
      protocol: _protocol,
      transport: _isTcpFamily ? _transport : (_isHysteria ? Transport.none : _transport),
      security: _security,
      uuid: _uuid.text.trim().isEmpty ? null : _uuid.text.trim(),
      password: _password.text.trim().isEmpty ? null : _password.text.trim(),
      alterId: int.tryParse(_alterId.text.trim()),
      path: _path.text.trim().isEmpty ? null : _path.text.trim(),
      host: _host.text.trim().isEmpty ? null : _host.text.trim(),
      sni: _sni.text.trim().isEmpty ? null : _sni.text.trim(),
      fingerprint: _fp.text.trim().isEmpty ? null : _fp.text.trim(),
      alpn: _alpn.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      flow: _flow.text.trim().isEmpty ? null : _flow.text.trim(),
      realityPublicKey:
          _pubKey.text.trim().isEmpty ? null : _pubKey.text.trim(),
      realityShortId:
          _shortId.text.trim().isEmpty ? null : _shortId.text.trim(),
      allowInsecure: _allowInsecure,
      ssMethod: _ssMethod.text.trim().isEmpty ? null : _ssMethod.text.trim(),
      hysteriaObfsPassword:
          _obfs.text.trim().isEmpty ? null : _obfs.text.trim(),
      hysteriaUpMbps: int.tryParse(_upMbps.text.trim()),
      hysteriaDownMbps: int.tryParse(_downMbps.text.trim()),
      source: widget.profile?.source ?? ProfileSource.manual,
      subscriptionId: widget.profile?.subscriptionId,
      rawParams: widget.profile?.rawParams ?? const {},
    );
    await widget.deps.profiles.update(profile);
    if (!mounted) return;
    Navigator.pop(context);
    _toast(widget.isEdit ? 'Node updated' : 'Node created');
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final l = Localizations.localeOf(context).languageCode == 'fa';
    final c = ThemeExt.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l
            ? (widget.isEdit ? 'ویرایش نود' : 'نود دستی')
            : (widget.isEdit ? 'EDIT NODE' : 'NEW NODE')),
        actions: [
          TextButton(onPressed: _save, child: Text(l ? 'ذخیره' : 'Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _label(context, l ? 'پروتکل' : 'PROTOCOL'),
          Wrap(
            spacing: 8,
            children: [
              for (final proto in [
                ProxyProtocol.vless,
                ProxyProtocol.vmess,
                ProxyProtocol.trojan,
                ProxyProtocol.shadowsocks,
                ProxyProtocol.hysteria2,
              ])
                ChoiceChip(
                  label: Text(proto.name),
                  selected: _protocol == proto,
                  onSelected: (_) => setState(() => _protocol = proto),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _field(context, _name, l ? 'نام' : 'Name'),
          Row(children: [
            Expanded(
              flex: 3,
              child: _field(context, _server, l ? 'سرور' : 'Server / address'),
            ),
            const SizedBox(width: 10),
            SizedBox(
                width: 92,
                child: _field(context, _port, l ? 'پورت' : 'Port')),
          ]),
          if (_needsUuid) _field(context, _uuid, 'UUID / UserID'),
          if (_protocol == ProxyProtocol.vmess)
            _field(context, _alterId, 'AlterId'),
          if (_needsPassword)
            _field(context, _password,
                _protocol == ProxyProtocol.shadowsocks ? 'Password' : 'Password'),
          if (_protocol == ProxyProtocol.shadowsocks)
            _field(context, _ssMethod, 'Cipher (e.g. 2022-blake3-aes-256-gcm)'),
          if (_isTcpFamily) ...[
            _label(context, l ? 'ترنسپورت' : 'TRANSPORT'),
            Wrap(
              spacing: 8,
              children: [
                for (final tp in [
                  Transport.ws,
                  Transport.grpc,
                  Transport.httpupgrade,
                  Transport.xhttp,
                  Transport.tcp,
                ])
                  ChoiceChip(
                    label: Text(tp.name),
                    selected: _transport == tp,
                    onSelected: (_) => setState(() => _transport = tp),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _label(context, l ? 'امنیت' : 'SECURITY'),
            Wrap(
              spacing: 8,
              children: [
                for (final sec in [
                  Security.none,
                  Security.tls,
                  Security.reality,
                ])
                  ChoiceChip(
                    label: Text(sec.name),
                    selected: _security == sec,
                    onSelected: (_) => setState(() => _security = sec),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_transport == Transport.ws ||
                _transport == Transport.xhttp ||
                _transport == Transport.httpupgrade)
              _field(context, _path, 'Path (e.g. /api)'),
            if (_transport == Transport.xhttp)
              _field(context, _host, 'Host / authority'),
            if (_security != Security.none) ...[
              _field(context, _sni, 'SNI (server name)'),
              _field(context, _alpn, 'ALPN (comma separated, e.g. h2,http/1.1)'),
              if (_security == Security.tls)
                _field(context, _fp, 'uTLS fingerprint (chrome/edge/…)'),
              if (_security == Security.reality) ...[
                _field(context, _pubKey, 'Reality public key'),
                _field(context, _shortId, 'Reality short-id'),
              ],
            ],
            if (_protocol == ProxyProtocol.vless && _security == Security.none)
              _field(context, _flow, 'Flow (e.g. xtls-rprx-vision)'),
          ],
          if (_isHysteria) ...[
            _field(context, _password, 'Password'),
            _field(context, _obfs, 'Obfs password (salamander)'),
            Row(children: [
              Expanded(
                  child: _field(context, _upMbps, l ? 'آپلود Mbps' : 'Up Mbps')),
              const SizedBox(width: 10),
              Expanded(
                  child:
                      _field(context, _downMbps, l ? 'دانلود Mbps' : 'Down Mbps')),
            ]),
            _field(context, _sni, 'SNI'),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l ? 'پذیرش گواهی نامعتبر (allowInsecure)'
                : 'Allow insecure certificate'),
            value: _allowInsecure,
            onChanged: (v) => setState(() => _allowInsecure = v),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _save,
            child: Text(l ? 'ساخت / ذخیره نود' : 'Save node'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              l
                  ? 'نکته: برای کانفیگ‌های آماده، «وارد کردن» لینک سریع‌تر است.'
                  : 'Tip: paste a share link via Import for ready-made configs.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(t,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: ThemeExt.of(context).textMuted)),
    );
  }

  Widget _field(BuildContext context, TextEditingController ctl, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: ctl,
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
  }
}
