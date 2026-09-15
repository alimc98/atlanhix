import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../settings/app_settings.dart';
import '../../theme/theme.dart';
import '../widgets/atlanhix_logo.dart';

/// v0.4.3: WARP is no longer a bottom-tab. It is a CHAIN MODIFIER shown
/// inline in Nodes and Dashboard: one hairline card that (a) states whether a
/// Cloudflare WARP account is registered (+ register button), (b) carries the
/// master switch, and (c) picks the chain order the user described:
///   config → WARP → Cloudflare IP   (WarpChainMode.chain: WARP last hop)
///   WARP → config                   (WarpChainMode.warpAsOutbound)
/// Tapping it is the whole flow — no other screen needed.
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

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final acct = widget.deps.warpRepo.account;
    final ready = acct != null && acct.privateKey.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: EdgeInsets.symmetric(
          horizontal: 14, vertical: widget.compact ? 10 : 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AtlanhixShieldMark(
                  size: 22, color: _s.warpEnabled ? c.accent : c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Localizations.localeOf(context).languageCode == 'fa'
                          ? 'Cloudflare WARP'
                          : 'CLOUDFLARE WARP',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(letterSpacing: 1.2),
                    ),
                    Text(
                      ready
                          ? (_s.warpEnabled
                              ? (Localizations.localeOf(context).languageCode ==
                                      'fa'
                                  ? 'زنجیر فعال'
                                  : 'chaining active')
                              : (Localizations.localeOf(context).languageCode ==
                                      'fa'
                                  ? 'ثبت‌شده — آماده'
                                  : 'registered — ready'))
                          : (Localizations.localeOf(context).languageCode == 'fa'
                              ? 'ثبت‌نام نشده'
                              : 'not registered'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.textMuted),
                    ),
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
                      : Text(Localizations.localeOf(context).languageCode ==
                              'fa'
                          ? 'ثبت‌نام'
                          : 'Register'),
                )
              else
                Switch(
                  value: _s.warpEnabled,
                  onChanged: (v) {
                    setState(() => _s.warpEnabled = v);
                    widget.deps.appSettingsRepo.save(_s);
                  },
                ),
            ],
          ),
          if (ready && _s.warpEnabled && !widget.compact)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<WarpChainMode>(
                segments: [
                  ButtonSegment(
                    value: WarpChainMode.chain,
                    label: Text(
                        Localizations.localeOf(context).languageCode == 'fa'
                            ? 'کانفیگ ← WARP ← IP کلادفلر'
                            : 'config → WARP → CF IP'),
                  ),
                  ButtonSegment(
                    value: WarpChainMode.warpAsOutbound,
                    label: Text(
                        Localizations.localeOf(context).languageCode == 'fa'
                            ? 'WARP ← کانفیگ'
                            : 'WARP → config'),
                  ),
                ],
                selected: {_s.warpChainMode},
                onSelectionChanged: (v) => _setChainMode(v.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),
        ],
      ),
    );
  }
}
