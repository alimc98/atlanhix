import '../routing/routing_models.dart';

/// Builtin routing profiles shipped with the app (§17). Each is a generic,
/// editable starting point — services are data, not hardcoded switches.
class BuiltinRoutingProfiles {
  static List<RoutingProfile> all() => [
        RoutingProfile(
          id: 'builtin-default',
          name: 'Default',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'd-1',
              matchType: RuleMatchType.domainSuffix,
              patterns: const ['.ir'],
              action: RoutingAction.direct,
              comment: 'Iranian domains direct',
            ),
          ],
        ),
        RoutingProfile(
          id: 'builtin-iran',
          name: 'Iran',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'ir-1',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                '.ir', 'irancell.ir', 'mci.ir', 'shaparak.ir', 'digikala.com',
                'snapp.ir', 'snapp.ir', 'tbank.ir', 'idpay.ir',
              ],
              action: RoutingAction.direct,
              comment: 'Iranian services direct',
            ),
            RoutingRule(
              id: 'ir-2',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                'telegram.org', 't.me', 'twitter.com', 'x.com', 'youtube.com',
                'googlevideo.com', 'instagram.com', 'facebook.com',
              ],
              action: RoutingAction.proxy,
              comment: 'Blocked services via proxy',
            ),
          ],
        ),
        RoutingProfile(
          id: 'builtin-google',
          name: 'Google services → WARP',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'g-1',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                'google.com', 'googleapis.com', 'gstatic.com', 'youtube.com',
                'googlevideo.com', 'ytimg.com', 'googleusercontent.com',
                'googletagmanager.com', 'google-analytics.com', 'recaptcha.net',
              ],
              action: RoutingAction.warp,
              comment: 'Google properties via WARP chain',
            ),
          ],
        ),
        RoutingProfile(
          id: 'builtin-ai',
          name: 'AI services',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'ai-1',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                'openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com',
                'claude.ai', 'anthropic.com', 'gemini.google.com',
                'perplexity.ai', 'huggingface.co',
              ],
              action: RoutingAction.proxy,
              comment: 'AI services via proxy',
            ),
          ],
        ),
        RoutingProfile(
          id: 'builtin-streaming',
          name: 'Streaming',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'st-1',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                'netflix.com', 'nflxvideo.net', 'nflximg.net', 'nflxext.com',
                'hulu.com', 'disneyplus.com', 'disney-plus.net', 'spotify.com',
                'scdn.co', 'primevideo.com',
              ],
              action: RoutingAction.proxy,
              comment: 'Streaming via proxy',
            ),
          ],
        ),
        RoutingProfile(
          id: 'builtin-gaming',
          name: 'Gaming',
          isBuiltin: true,
          rules: [
            RoutingRule(
              id: 'gm-1',
              matchType: RuleMatchType.network,
              patterns: const ['udp'],
              action: RoutingAction.direct,
              comment: 'UDP games direct (latency)',
            ),
            RoutingRule(
              id: 'gm-2',
              matchType: RuleMatchType.domainSuffix,
              patterns: const [
                'steamcontent.com', 'steamserver.net', 'epicgames.com',
                'riotgames.com', 'battlenet.com', 'xboxlive.com',
              ],
              action: RoutingAction.direct,
              comment: 'Game downloads & matchmaking direct',
            ),
          ],
        ),
      ];
}
