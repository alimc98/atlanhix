import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../settings/app_settings.dart';
import '../../theme/theme.dart';
import '../widgets/atlanhix_logo.dart';

/// v0.4.8 §user — WARP chain modes card (rewritten from the v0.4.3 card).
///
/// Three REAL modes (the legacy on/off split is gone):
///  * off       — plain topology, no WARP endpoint in the config.
///  * warpFirst — WARP dials the node: app → WARP → node → internet. For
///    filtered nodes: the censor never sees the node's handshake. With
///    AmneziaWG 3.1 params the WARP hop itself survives carrier DPI.
///  * warpLast  — the node dials WARP: app → node → WARP → internet. For
///    sanctions: the exit IP is Cloudflare's.
///
/// The card also carries the manual AWG parameter sheet: the user pastes
/// the values warp-generator.vercel.app gives (WARP-on-AWG-2 style) —
/// Jc/Jmin/Jmax/S1/S2/H1..H4 — or leaves them empty for plain WARP.
/// Params persist on the account (WarpRepository) and ride every chain.
class WarpChainCard extends StatefulWidget {
  const WarpChainCard({super.key, required this.deps, this.compact = false});

  final AppDependencies deps;
  final bool compact;

  @override
  State<WarpChainCard> createState() => _WarpChainCardState();
}

class _WarpChainCardState extends State<WarpChainCard> {
  bool _busy = false;

  AppSettings get _s => widget.deps.appSettings;
  bool get _fa => Localizations.localeOf(context).languageCode == 'fa';

  Future<void> _register() async {
    setState(() => _busy = true);
    String msg;
    try {
      final acct = await widget.deps.warpService.register();
      await widget.deps.warpRepo.save(acct);
      msg = 'WARP OK';
    } catch (e) {
      msg = 'WARP failed';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _setChainMode(WarpChainMode m) {
    setState(() => _s.warpChainMode = m);
    widget.deps.appSettingsRepo.save(_s);
  }

  /// The AWG params sheet — manual entry per the user's request: values
  /// from warp-generator.vercel.app (AWG-2) or any AWG-3.1 generator paste
  /// straight in. Save → persisted on the account → the next connect's
  /// WARP endpoint carries them. The full 3.x surface is exposed:
  /// junk (Jc/Jmin/Jmax), paddings (S1..S4), header remap (H1..H4, single
  /// value or N-M range), decoy packets (I1..I5 tag DSL) and the 3.x-only
  /// header-protection key (Hpk).
  Future<void> _editAwgParams() async {
    final a = widget.deps.warpRepo.account;
    if (a == null) return;
    final jc = TextEditingController(text: a.awgJc?.toString() ?? '');
    final jmin = TextEditingController(text: a.awgJmin?.toString() ?? '');
    final jmax = TextEditingController(text: a.awgJmax?.toString() ?? '');
    final s1 = TextEditingController(text: a.awgS1?.toString() ?? '');
    final s2 = TextEditingController(text: a.awgS2?.toString() ?? '');
    final s3 = TextEditingController(text: a.awgS3?.toString() ?? '');
    final s4 = TextEditingController(text: a.awgS4?.toString() ?? '');
    final h1 = TextEditingController(text: a.awgH1 ?? '');
    final h2 = TextEditingController(text: a.awgH2 ?? '');
    final h3 = TextEditingController(text: a.awgH3 ?? '');
    final h4 = TextEditingController(text: a.awgH4 ?? '');
    final i1 = TextEditingController(text: a.awgI1 ?? '');
    final i2 = TextEditingController(text: a.awgI2 ?? '');
    final i3 = TextEditingController(text: a.awgI3 ?? '');
    final i4 = TextEditingController(text: a.awgI4 ?? '');
    final i5 = TextEditingController(text: a.awgI5 ?? '');
    final hpk = TextEditingController(text: a.awgHpk ?? '');

    int? p(TextEditingController c) => int.tryParse(c.text.trim());
    String? s(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: Text(_fa ? 'پارامترهای AmneziaWG 3.x'
            : 'AmneziaWG 3.x parameters'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _fa
                    ? 'مقادیر تولیدشده را وارد کنید؛ خالی = وارپ ساده. H می‌تواند عدد یا بازه‌ی N-M باشد؛ Iها بسته‌های فریب‌اند (اختیاری).'
                    : 'Paste the generated values; empty = plain WARP. H accepts a number or an N-M range; I are decoy packets (optional).',
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: ThemeExt.of(ctx).textSecondary),
              ),
            ),
            for (final e in <String, TextEditingController>{
              'Jc': jc, 'Jmin': jmin, 'Jmax': jmax,
              'S1': s1, 'S2': s2, 'S3': s3, 'S4': s4,
              'H1': h1, 'H2': h2, 'H3': h3, 'H4': h4,
              'I1': i1, 'I2': i2, 'I3': i3, 'I4': i4, 'I5': i5,
              'Hpk': hpk,
            }.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: TextField(
                  controller: e.value,
                  // H ranges, I tag-DSL strings and the Hpk key are not
                  // numeric-only inputs.
                  keyboardType: e.key.startsWith('H') && e.key != 'Hpk'
                      ? TextInputType.text
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: e.key,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_fa ? 'انصراف' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_fa ? 'ذخیره' : 'Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Persist through the repository's copy-with-secrets save (secrets
    // never round-trip through the dialog; we only patch the AWG params).
    await widget.deps.warpRepo.saveWithAwgParams(
      jc: p(jc),
      jmin: p(jmin),
      jmax: p(jmax),
      s1: p(s1),
      s2: p(s2),
      s3: p(s3),
      s4: p(s4),
      h1: s(h1),
      h2: s(h2),
      h3: s(h3),
      h4: s(h4),
      i1: s(i1),
      i2: s(i2),
      i3: s(i3),
      i4: s(i4),
      i5: s(i5),
      hpk: s(hpk),
    );
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_fa
            ? 'پارامترهای AWG ذخیره شد — روی اتصال بعدی اعمال می‌شود'
            : 'AWG params saved — applied on the next connect')));
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final acct = widget.deps.warpRepo.account;
    final ready = acct != null && acct.privateKey.isNotEmpty;
    final mode = _s.warpChainMode;
    final subtitle = !ready
        ? (_fa ? 'ثبت‌نام نشده' : 'not registered')
        : switch (mode) {
            WarpChainMode.off => (_fa ? 'غیرفعال' : 'off'),
            WarpChainMode.warpFirst => (_fa
                ? 'WARP ← کانفیگ (نود فیلتر)'
                : 'WARP first (filtered node)'),
            WarpChainMode.warpLast => (_fa
                ? 'کانفیگ ← WARP ← IP کلادفلر'
                : 'config → WARP (CF exit IP)'),
          };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: EdgeInsets.symmetric(
          horizontal: 14, vertical: widget.compact ? 10 : 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(
            color: mode != WarpChainMode.off ? c.textPrimary : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AtlanhixShieldMark(
                  size: 22,
                  color: mode != WarpChainMode.off ? c.accent : c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fa ? 'Cloudflare WARP' : 'CLOUDFLARE WARP',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(letterSpacing: 1.2),
                    ),
                    Text(subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.textMuted)),
                  ],
                ),
              ),
              if (!ready)
                TextButton(
                  onPressed: _busy ? null : _register,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_fa ? 'ثبت‌نام' : 'Register'),
                ),
            ],
          ),
          if (ready) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<WarpChainMode>(
                segments: [
                  ButtonSegment(
                      value: WarpChainMode.off,
                      label: Text(_fa ? 'خاموش' : 'Off')),
                  ButtonSegment(
                      value: WarpChainMode.warpFirst,
                      label: Text(_fa ? 'WARP اول' : 'WARP first')),
                  ButtonSegment(
                      value: WarpChainMode.warpLast,
                      label: Text(_fa ? 'WARP آخر' : 'WARP last')),
                ],
                selected: {mode},
                onSelectionChanged: (v) => _setChainMode(v.first),
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact),
              ),
            ),
            // Direction explainer — which chain the selected mode builds.
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
              child: Text(
                switch (mode) {
                  WarpChainMode.off =>
                    _fa
                        ? 'بدون وارپ — توپولوژی ساده'
                        : 'no WARP — plain topology',
                  WarpChainMode.warpFirst =>
                    _fa
                        ? 'دستگاه ← WARP ← نود ← اینترنت — برای نودهای فیلترشده'
                        : 'device → WARP → node → internet — for filtered nodes',
                  WarpChainMode.warpLast =>
                    _fa
                        ? 'دستگاه ← نود ← WARP ← اینترنت — خروج IP کلادفلر'
                        : 'device → node → WARP → internet — Cloudflare exit IP',
                },
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: c.textSecondary),
              ),
            ),
            // v0.4.8 §user: the AWG-3.1 params entry (manual, per account).
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _editAwgParams,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.surfaceElevated,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.enhanced_encryption,
                          size: 18,
                          color: (acct.hasAmneziaParams
                              ? c.success
                              : c.textSecondary)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          acct.hasAmneziaParams
                              ? (_fa
                                  ? 'AmneziaWG 3.1 فعال (پارامترهای دستی)'
                                  : 'AmneziaWG 3.1 active (manual params)')
                              : (_fa
                                  ? 'پارامترهای AmneziaWG 3.1 (دستی)'
                                  : 'AmneziaWG 3.1 params (manual)'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: acct.hasAmneziaParams
                                      ? c.textPrimary
                                      : c.textSecondary),
                        ),
                      ),
                      Icon(Icons.edit_outlined,
                          size: 16, color: c.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
