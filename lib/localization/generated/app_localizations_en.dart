// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Atlanhix';

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navNodes => 'Nodes';

  @override
  String get navSubscriptions => 'Subscriptions';

  @override
  String get navWarp => 'WARP';

  @override
  String get navRouting => 'Routing';

  @override
  String get navLogs => 'Logs';

  @override
  String get navSettings => 'Settings';

  @override
  String get navChain => 'Chain Builder';

  @override
  String get navDiagnostics => 'Diagnostics';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get connecting => 'Connecting…';

  @override
  String get connected => 'Connected';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get smartConnect => 'Smart Connect';

  @override
  String get testAllNodes => 'Test all nodes';

  @override
  String get testing => 'Testing…';

  @override
  String get currentNode => 'Current node';

  @override
  String get notConnected => 'Not connected';

  @override
  String get noNodeSelected => 'No node selected';

  @override
  String get selectNode => 'Select a node';

  @override
  String get currentIp => 'Current IP';

  @override
  String get uploadSpeed => 'Upload';

  @override
  String get downloadSpeed => 'Download';

  @override
  String get session => 'Session';

  @override
  String get quickActions => 'Quick Actions';

  @override
  String get autoSelect => 'Auto Select';

  @override
  String get protocol => 'Protocol';

  @override
  String get core => 'Core';

  @override
  String get transport => 'Transport';

  @override
  String get security => 'Security';

  @override
  String get server => 'Server';

  @override
  String get port => 'Port';

  @override
  String get latency => 'Latency';

  @override
  String get stability => 'Stability';

  @override
  String get successRate => 'Success rate';

  @override
  String get lastChecked => 'Last checked';

  @override
  String get health => 'Health';

  @override
  String get healthUnknown => 'Unknown';

  @override
  String get healthChecking => 'Checking';

  @override
  String get healthHealthy => 'Healthy';

  @override
  String get healthDegraded => 'Degraded';

  @override
  String get healthTimeout => 'Timeout';

  @override
  String get healthOffline => 'Offline';

  @override
  String get healthBlocked => 'Blocked';

  @override
  String get healthCoreError => 'Core error';

  @override
  String get healthConfigError => 'Config error';

  @override
  String get noNodes => 'No nodes yet';

  @override
  String get noNodesHint =>
      'Import a subscription, paste a link, or add a node manually.';

  @override
  String get import => 'Import';

  @override
  String get addManually => 'Add manually';

  @override
  String get fromClipboard => 'From clipboard';

  @override
  String get fromFile => 'From file';

  @override
  String get fromQr => 'QR code';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get duplicate => 'Duplicate';

  @override
  String get exportNode => 'Export';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get retry => 'Retry';

  @override
  String get close => 'Close';

  @override
  String get details => 'Details';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get clear => 'Clear';

  @override
  String get search => 'Search';

  @override
  String get filterAll => 'All';

  @override
  String get filterHealthy => 'Healthy';

  @override
  String get filterFast => 'Fast';

  @override
  String get sortByLatency => 'Latency';

  @override
  String get sortByName => 'Name';

  @override
  String get sortByStability => 'Stability';

  @override
  String get sortByCountry => 'Country';

  @override
  String get connectToNode => 'Connect';

  @override
  String get testNode => 'Test';

  @override
  String get addToChain => 'Add to chain';

  @override
  String get showConfig => 'Configuration preview';

  @override
  String get noSubscription => 'No subscriptions';

  @override
  String get noSubscriptionHint =>
      'Add a subscription URL to keep nodes in sync with your provider.';

  @override
  String get addSubscription => 'Add subscription';

  @override
  String get subscriptionName => 'Name';

  @override
  String get subscriptionUrl => 'Subscription URL';

  @override
  String get updateNow => 'Update now';

  @override
  String get autoUpdate => 'Auto update';

  @override
  String get lastUpdated => 'Last updated';

  @override
  String get nextUpdate => 'Next update';

  @override
  String get nodesCount => 'Nodes';

  @override
  String get healthyCount => 'Healthy';

  @override
  String get usedTraffic => 'Used';

  @override
  String get remainingTraffic => 'Remaining';

  @override
  String get totalTraffic => 'Total';

  @override
  String get uploadTraffic => 'Upload';

  @override
  String get downloadTraffic => 'Download';

  @override
  String get expires => 'Expires';

  @override
  String get neverExpires => 'Never';

  @override
  String daysLeft(int n) {
    return '$n days left';
  }

  @override
  String get updating => 'Updating…';

  @override
  String get updateFailed => 'Update failed';

  @override
  String get warpTitle => 'WARP';

  @override
  String get warpReady => 'Ready';

  @override
  String get warpNotRegistered => 'Not registered';

  @override
  String get warpGenerate => 'Generate';

  @override
  String get warpRegenerate => 'Regenerate';

  @override
  String get warpExport => 'Export';

  @override
  String get warpLicense => 'License';

  @override
  String get warpStatus => 'Status';

  @override
  String get chainBuilder => 'Chain Builder';

  @override
  String get addNodeToChain => 'Add node';

  @override
  String get addWarpToChain => 'Add WARP';

  @override
  String get testChain => 'Test chain';

  @override
  String get saveChain => 'Save chain';

  @override
  String get chainName => 'Chain name';

  @override
  String get invalidChain => 'This chain cannot be started';

  @override
  String get internet => 'Internet';

  @override
  String get routingProfiles => 'Routing profiles';

  @override
  String get newRule => 'New rule';

  @override
  String get ruleDomain => 'Domain';

  @override
  String get ruleDomainSuffix => 'Domain suffix';

  @override
  String get ruleKeyword => 'Keyword';

  @override
  String get ruleIp => 'IP / CIDR';

  @override
  String get ruleGeoip => 'GeoIP';

  @override
  String get ruleProcess => 'Process';

  @override
  String get rulePackage => 'Android app';

  @override
  String get actionDirect => 'Direct';

  @override
  String get actionProxy => 'Proxy';

  @override
  String get actionWarp => 'WARP';

  @override
  String get actionBlock => 'Block';

  @override
  String get actionChain => 'Chain';

  @override
  String get dnsMode => 'DNS mode';

  @override
  String get dnsSystem => 'System';

  @override
  String get dnsAutomatic => 'Automatic';

  @override
  String get dnsCustom => 'Custom';

  @override
  String get dnsDoh => 'DNS over HTTPS';

  @override
  String get dnsDot => 'DNS over TLS';

  @override
  String get dnsFakeip => 'Fake-IP';

  @override
  String get appearance => 'Appearance';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeLight => 'Light';

  @override
  String get themeOled => 'OLED';

  @override
  String get language => 'Language';

  @override
  String get simpleMode => 'Simple mode';

  @override
  String get advancedMode => 'Advanced mode';

  @override
  String get notifications => 'Notifications';

  @override
  String get privacyMode => 'Privacy mode';

  @override
  String get autoTest => 'Auto Test';

  @override
  String get testUrl => 'Test URL';

  @override
  String get interval => 'Interval';

  @override
  String get seconds => 's';

  @override
  String get failureThreshold => 'Failure threshold';

  @override
  String get recoveryThreshold => 'Recovery threshold';

  @override
  String get fragmentation => 'Fragmentation';

  @override
  String get fragmentOff => 'Off';

  @override
  String get tunMode => 'TUN mode';

  @override
  String get systemProxy => 'System proxy';

  @override
  String get connectionMode => 'Connection mode';

  @override
  String get modeOff => 'Off';

  @override
  String get modeBoth => 'Managed';

  @override
  String get general => 'General';

  @override
  String get connection => 'Connection';

  @override
  String get cores => 'Cores';

  @override
  String get advanced => 'Advanced';

  @override
  String get about => 'About';

  @override
  String get version => 'Version';

  @override
  String get openLicenses => 'Third-party licenses';

  @override
  String get clearLogs => 'Clear logs';

  @override
  String get exportLogs => 'Export logs';

  @override
  String get runDiagnostics => 'Run diagnostics';

  @override
  String get diagDns => 'DNS';

  @override
  String get diagTcp => 'TCP';

  @override
  String get diagTls => 'TLS';

  @override
  String get diagHttp => 'HTTP';

  @override
  String get diagProxy => 'Proxy';

  @override
  String get likelyProblem => 'Likely problem';

  @override
  String get viewLogs => 'View logs';

  @override
  String get configPreview => 'Configuration preview';

  @override
  String get originalConfig => 'Original';

  @override
  String get generatedConfig => 'Generated';

  @override
  String get validate => 'Validate';

  @override
  String get configValid => 'Configuration is valid';

  @override
  String get configInvalid => 'Configuration has problems';

  @override
  String get coreDetection => 'Core detection';

  @override
  String get confidence => 'Confidence';

  @override
  String get reasons => 'Reasons';

  @override
  String switchedNode(String name) {
    return 'Switched to $name';
  }

  @override
  String autoSwitched(String name) {
    return 'Auto-switched to $name';
  }

  @override
  String get nodeUnhealthy => 'Node unhealthy';

  @override
  String subscriptionUpdated(int before, int after) {
    return 'Subscription updated: $before â†’ $after nodes';
  }

  @override
  String get coreCrashed => 'Core crashed and is restarting';

  @override
  String importSuccess(int count) {
    return 'Imported $count nodes';
  }

  @override
  String importPartial(int count, int skipped) {
    return 'Imported $count nodes, $skipped skipped';
  }

  @override
  String get importFailed => 'Import failed';

  @override
  String get engineMissing => 'Engine not installed';

  @override
  String engineMissingHint(String engine) {
    return 'Place the $engine binary in the cores folder or set its path in Settings.';
  }

  @override
  String get quickSettings => 'Quick Settings';

  @override
  String get recommendedNodes => 'Recommended Nodes';

  @override
  String get tapToConnect => 'Tap to connect';

  @override
  String get download => 'Download';

  @override
  String get upload => 'Upload';

  @override
  String get time => 'Time';

  @override
  String get pillIranApps => 'Iran Apps';

  @override
  String get pillAds => 'Ads';

  @override
  String get pillProxyMode => 'Proxy Mode';

  @override
  String get pillTlsFragment => 'Split HTTPS';

  @override
  String get modeTun => 'TUN';

  @override
  String get modeProxy => 'Proxy';

  @override
  String screeningSummary(Object risky, Object xrayOnly) {
    return '$xrayOnly Xray-only nodes, $risky with stream warnings';
  }

  @override
  String get clipboardAddTitle => 'Add from clipboard?';

  @override
  String clipboardAddBody(Object count) {
    return '$count share link(s) were detected in your clipboard. Add them to Atlanhix?';
  }

  @override
  String get clipboardAddNodes => 'Add nodes';

  @override
  String get clipboardAddSubscription => 'Add subscription';

  @override
  String get clipboardLater => 'Later';

  @override
  String get warpOfferTitle => 'Node looks filtered';

  @override
  String warpOfferBody(Object count, Object node) {
    return '$node did not answer $count URL tests through the tunnel. Enable the WARP chain in front of it? (You can turn WARP off any time.)';
  }

  @override
  String get warpOfferEnable => 'Chain WARP';
}
