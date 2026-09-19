import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Atlanhix'**
  String get appName;

  /// No description provided for @navDashboard.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get navDashboard;

  /// No description provided for @navNodes.
  ///
  /// In en, this message translates to:
  /// **'Nodes'**
  String get navNodes;

  /// No description provided for @navSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get navSubscriptions;

  /// No description provided for @navWarp.
  ///
  /// In en, this message translates to:
  /// **'WARP'**
  String get navWarp;

  /// No description provided for @navRouting.
  ///
  /// In en, this message translates to:
  /// **'Routing'**
  String get navRouting;

  /// No description provided for @navLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get navLogs;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navChain.
  ///
  /// In en, this message translates to:
  /// **'Chain Builder'**
  String get navChain;

  /// No description provided for @navDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get navDiagnostics;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connectingâ€¦'**
  String get connecting;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @smartConnect.
  ///
  /// In en, this message translates to:
  /// **'Smart Connect'**
  String get smartConnect;

  /// No description provided for @testAllNodes.
  ///
  /// In en, this message translates to:
  /// **'Test all nodes'**
  String get testAllNodes;

  /// No description provided for @testing.
  ///
  /// In en, this message translates to:
  /// **'Testingâ€¦'**
  String get testing;

  /// No description provided for @currentNode.
  ///
  /// In en, this message translates to:
  /// **'Current node'**
  String get currentNode;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @noNodeSelected.
  ///
  /// In en, this message translates to:
  /// **'No node selected'**
  String get noNodeSelected;

  /// No description provided for @selectNode.
  ///
  /// In en, this message translates to:
  /// **'Select a node'**
  String get selectNode;

  /// No description provided for @currentIp.
  ///
  /// In en, this message translates to:
  /// **'Current IP'**
  String get currentIp;

  /// No description provided for @uploadSpeed.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get uploadSpeed;

  /// No description provided for @downloadSpeed.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get downloadSpeed;

  /// No description provided for @session.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get session;

  /// No description provided for @quickActions.
  ///
  /// In en, this message translates to:
  /// **'Quick Actions'**
  String get quickActions;

  /// No description provided for @autoSelect.
  ///
  /// In en, this message translates to:
  /// **'Auto Select'**
  String get autoSelect;

  /// No description provided for @protocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get protocol;

  /// No description provided for @core.
  ///
  /// In en, this message translates to:
  /// **'Core'**
  String get core;

  /// No description provided for @transport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get transport;

  /// No description provided for @security.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get security;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @latency.
  ///
  /// In en, this message translates to:
  /// **'Latency'**
  String get latency;

  /// No description provided for @stability.
  ///
  /// In en, this message translates to:
  /// **'Stability'**
  String get stability;

  /// No description provided for @successRate.
  ///
  /// In en, this message translates to:
  /// **'Success rate'**
  String get successRate;

  /// No description provided for @lastChecked.
  ///
  /// In en, this message translates to:
  /// **'Last checked'**
  String get lastChecked;

  /// No description provided for @health.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get health;

  /// No description provided for @healthUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get healthUnknown;

  /// No description provided for @healthChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get healthChecking;

  /// No description provided for @healthHealthy.
  ///
  /// In en, this message translates to:
  /// **'Healthy'**
  String get healthHealthy;

  /// No description provided for @healthDegraded.
  ///
  /// In en, this message translates to:
  /// **'Degraded'**
  String get healthDegraded;

  /// No description provided for @healthTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get healthTimeout;

  /// No description provided for @healthOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get healthOffline;

  /// No description provided for @healthBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get healthBlocked;

  /// No description provided for @healthCoreError.
  ///
  /// In en, this message translates to:
  /// **'Core error'**
  String get healthCoreError;

  /// No description provided for @healthConfigError.
  ///
  /// In en, this message translates to:
  /// **'Config error'**
  String get healthConfigError;

  /// No description provided for @noNodes.
  ///
  /// In en, this message translates to:
  /// **'No nodes yet'**
  String get noNodes;

  /// No description provided for @noNodesHint.
  ///
  /// In en, this message translates to:
  /// **'Import a subscription, paste a link, or add a node manually.'**
  String get noNodesHint;

  /// No description provided for @import.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get import;

  /// No description provided for @addManually.
  ///
  /// In en, this message translates to:
  /// **'Add manually'**
  String get addManually;

  /// No description provided for @fromClipboard.
  ///
  /// In en, this message translates to:
  /// **'From clipboard'**
  String get fromClipboard;

  /// No description provided for @fromFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get fromFile;

  /// No description provided for @fromQr.
  ///
  /// In en, this message translates to:
  /// **'QR code'**
  String get fromQr;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @duplicate.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get duplicate;

  /// No description provided for @exportNode.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get exportNode;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @filterHealthy.
  ///
  /// In en, this message translates to:
  /// **'Healthy'**
  String get filterHealthy;

  /// No description provided for @filterFast.
  ///
  /// In en, this message translates to:
  /// **'Fast'**
  String get filterFast;

  /// No description provided for @sortByLatency.
  ///
  /// In en, this message translates to:
  /// **'Latency'**
  String get sortByLatency;

  /// No description provided for @sortByName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get sortByName;

  /// No description provided for @sortByStability.
  ///
  /// In en, this message translates to:
  /// **'Stability'**
  String get sortByStability;

  /// No description provided for @sortByCountry.
  ///
  /// In en, this message translates to:
  /// **'Country'**
  String get sortByCountry;

  /// No description provided for @connectToNode.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectToNode;

  /// No description provided for @testNode.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get testNode;

  /// No description provided for @addToChain.
  ///
  /// In en, this message translates to:
  /// **'Add to chain'**
  String get addToChain;

  /// No description provided for @showConfig.
  ///
  /// In en, this message translates to:
  /// **'Configuration preview'**
  String get showConfig;

  /// No description provided for @noSubscription.
  ///
  /// In en, this message translates to:
  /// **'No subscriptions'**
  String get noSubscription;

  /// No description provided for @noSubscriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Add a subscription URL to keep nodes in sync with your provider.'**
  String get noSubscriptionHint;

  /// No description provided for @addSubscription.
  ///
  /// In en, this message translates to:
  /// **'Add subscription'**
  String get addSubscription;

  /// No description provided for @subscriptionName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get subscriptionName;

  /// No description provided for @subscriptionUrl.
  ///
  /// In en, this message translates to:
  /// **'Subscription URL'**
  String get subscriptionUrl;

  /// No description provided for @updateNow.
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get updateNow;

  /// No description provided for @autoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Auto update'**
  String get autoUpdate;

  /// No description provided for @lastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last updated'**
  String get lastUpdated;

  /// No description provided for @nextUpdate.
  ///
  /// In en, this message translates to:
  /// **'Next update'**
  String get nextUpdate;

  /// No description provided for @nodesCount.
  ///
  /// In en, this message translates to:
  /// **'Nodes'**
  String get nodesCount;

  /// No description provided for @healthyCount.
  ///
  /// In en, this message translates to:
  /// **'Healthy'**
  String get healthyCount;

  /// No description provided for @usedTraffic.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get usedTraffic;

  /// No description provided for @remainingTraffic.
  ///
  /// In en, this message translates to:
  /// **'Remaining'**
  String get remainingTraffic;

  /// No description provided for @totalTraffic.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get totalTraffic;

  /// No description provided for @uploadTraffic.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get uploadTraffic;

  /// No description provided for @downloadTraffic.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get downloadTraffic;

  /// No description provided for @expires.
  ///
  /// In en, this message translates to:
  /// **'Expires'**
  String get expires;

  /// No description provided for @neverExpires.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get neverExpires;

  /// No description provided for @daysLeft.
  ///
  /// In en, this message translates to:
  /// **'{n} days left'**
  String daysLeft(int n);

  /// No description provided for @updating.
  ///
  /// In en, this message translates to:
  /// **'Updatingâ€¦'**
  String get updating;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed'**
  String get updateFailed;

  /// No description provided for @warpTitle.
  ///
  /// In en, this message translates to:
  /// **'WARP'**
  String get warpTitle;

  /// No description provided for @warpReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get warpReady;

  /// No description provided for @warpNotRegistered.
  ///
  /// In en, this message translates to:
  /// **'Not registered'**
  String get warpNotRegistered;

  /// No description provided for @warpGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get warpGenerate;

  /// No description provided for @warpRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get warpRegenerate;

  /// No description provided for @warpExport.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get warpExport;

  /// No description provided for @warpLicense.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get warpLicense;

  /// No description provided for @warpStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get warpStatus;

  /// No description provided for @chainBuilder.
  ///
  /// In en, this message translates to:
  /// **'Chain Builder'**
  String get chainBuilder;

  /// No description provided for @addNodeToChain.
  ///
  /// In en, this message translates to:
  /// **'Add node'**
  String get addNodeToChain;

  /// No description provided for @addWarpToChain.
  ///
  /// In en, this message translates to:
  /// **'Add WARP'**
  String get addWarpToChain;

  /// No description provided for @testChain.
  ///
  /// In en, this message translates to:
  /// **'Test chain'**
  String get testChain;

  /// No description provided for @saveChain.
  ///
  /// In en, this message translates to:
  /// **'Save chain'**
  String get saveChain;

  /// No description provided for @chainName.
  ///
  /// In en, this message translates to:
  /// **'Chain name'**
  String get chainName;

  /// No description provided for @invalidChain.
  ///
  /// In en, this message translates to:
  /// **'This chain cannot be started'**
  String get invalidChain;

  /// No description provided for @internet.
  ///
  /// In en, this message translates to:
  /// **'Internet'**
  String get internet;

  /// No description provided for @routingProfiles.
  ///
  /// In en, this message translates to:
  /// **'Routing profiles'**
  String get routingProfiles;

  /// No description provided for @newRule.
  ///
  /// In en, this message translates to:
  /// **'New rule'**
  String get newRule;

  /// No description provided for @ruleDomain.
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get ruleDomain;

  /// No description provided for @ruleDomainSuffix.
  ///
  /// In en, this message translates to:
  /// **'Domain suffix'**
  String get ruleDomainSuffix;

  /// No description provided for @ruleKeyword.
  ///
  /// In en, this message translates to:
  /// **'Keyword'**
  String get ruleKeyword;

  /// No description provided for @ruleIp.
  ///
  /// In en, this message translates to:
  /// **'IP / CIDR'**
  String get ruleIp;

  /// No description provided for @ruleGeoip.
  ///
  /// In en, this message translates to:
  /// **'GeoIP'**
  String get ruleGeoip;

  /// No description provided for @ruleProcess.
  ///
  /// In en, this message translates to:
  /// **'Process'**
  String get ruleProcess;

  /// No description provided for @rulePackage.
  ///
  /// In en, this message translates to:
  /// **'Android app'**
  String get rulePackage;

  /// No description provided for @actionDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get actionDirect;

  /// No description provided for @actionProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get actionProxy;

  /// No description provided for @actionWarp.
  ///
  /// In en, this message translates to:
  /// **'WARP'**
  String get actionWarp;

  /// No description provided for @actionBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get actionBlock;

  /// No description provided for @actionChain.
  ///
  /// In en, this message translates to:
  /// **'Chain'**
  String get actionChain;

  /// No description provided for @dnsMode.
  ///
  /// In en, this message translates to:
  /// **'DNS mode'**
  String get dnsMode;

  /// No description provided for @dnsSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get dnsSystem;

  /// No description provided for @dnsAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get dnsAutomatic;

  /// No description provided for @dnsCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get dnsCustom;

  /// No description provided for @dnsDoh.
  ///
  /// In en, this message translates to:
  /// **'DNS over HTTPS'**
  String get dnsDoh;

  /// No description provided for @dnsDot.
  ///
  /// In en, this message translates to:
  /// **'DNS over TLS'**
  String get dnsDot;

  /// No description provided for @dnsFakeip.
  ///
  /// In en, this message translates to:
  /// **'Fake-IP'**
  String get dnsFakeip;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeOled.
  ///
  /// In en, this message translates to:
  /// **'OLED'**
  String get themeOled;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @simpleMode.
  ///
  /// In en, this message translates to:
  /// **'Simple mode'**
  String get simpleMode;

  /// No description provided for @advancedMode.
  ///
  /// In en, this message translates to:
  /// **'Advanced mode'**
  String get advancedMode;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @privacyMode.
  ///
  /// In en, this message translates to:
  /// **'Privacy mode'**
  String get privacyMode;

  /// No description provided for @autoTest.
  ///
  /// In en, this message translates to:
  /// **'Auto Test'**
  String get autoTest;

  /// No description provided for @testUrl.
  ///
  /// In en, this message translates to:
  /// **'Test URL'**
  String get testUrl;

  /// No description provided for @interval.
  ///
  /// In en, this message translates to:
  /// **'Interval'**
  String get interval;

  /// No description provided for @seconds.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get seconds;

  /// No description provided for @failureThreshold.
  ///
  /// In en, this message translates to:
  /// **'Failure threshold'**
  String get failureThreshold;

  /// No description provided for @recoveryThreshold.
  ///
  /// In en, this message translates to:
  /// **'Recovery threshold'**
  String get recoveryThreshold;

  /// No description provided for @fragmentation.
  ///
  /// In en, this message translates to:
  /// **'Fragmentation'**
  String get fragmentation;

  /// No description provided for @fragmentOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get fragmentOff;

  /// No description provided for @tunMode.
  ///
  /// In en, this message translates to:
  /// **'TUN mode'**
  String get tunMode;

  /// No description provided for @systemProxy.
  ///
  /// In en, this message translates to:
  /// **'System proxy'**
  String get systemProxy;

  /// No description provided for @connectionMode.
  ///
  /// In en, this message translates to:
  /// **'Connection mode'**
  String get connectionMode;

  /// No description provided for @modeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get modeOff;

  /// No description provided for @modeBoth.
  ///
  /// In en, this message translates to:
  /// **'Managed'**
  String get modeBoth;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @connection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get connection;

  /// No description provided for @cores.
  ///
  /// In en, this message translates to:
  /// **'Cores'**
  String get cores;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @openLicenses.
  ///
  /// In en, this message translates to:
  /// **'Third-party licenses'**
  String get openLicenses;

  /// No description provided for @clearLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get clearLogs;

  /// No description provided for @exportLogs.
  ///
  /// In en, this message translates to:
  /// **'Export logs'**
  String get exportLogs;

  /// No description provided for @runDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Run diagnostics'**
  String get runDiagnostics;

  /// No description provided for @diagDns.
  ///
  /// In en, this message translates to:
  /// **'DNS'**
  String get diagDns;

  /// No description provided for @diagTcp.
  ///
  /// In en, this message translates to:
  /// **'TCP'**
  String get diagTcp;

  /// No description provided for @diagTls.
  ///
  /// In en, this message translates to:
  /// **'TLS'**
  String get diagTls;

  /// No description provided for @diagHttp.
  ///
  /// In en, this message translates to:
  /// **'HTTP'**
  String get diagHttp;

  /// No description provided for @diagProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get diagProxy;

  /// No description provided for @likelyProblem.
  ///
  /// In en, this message translates to:
  /// **'Likely problem'**
  String get likelyProblem;

  /// No description provided for @viewLogs.
  ///
  /// In en, this message translates to:
  /// **'View logs'**
  String get viewLogs;

  /// No description provided for @configPreview.
  ///
  /// In en, this message translates to:
  /// **'Configuration preview'**
  String get configPreview;

  /// No description provided for @originalConfig.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get originalConfig;

  /// No description provided for @generatedConfig.
  ///
  /// In en, this message translates to:
  /// **'Generated'**
  String get generatedConfig;

  /// No description provided for @validate.
  ///
  /// In en, this message translates to:
  /// **'Validate'**
  String get validate;

  /// No description provided for @configValid.
  ///
  /// In en, this message translates to:
  /// **'Configuration is valid'**
  String get configValid;

  /// No description provided for @configInvalid.
  ///
  /// In en, this message translates to:
  /// **'Configuration has problems'**
  String get configInvalid;

  /// No description provided for @coreDetection.
  ///
  /// In en, this message translates to:
  /// **'Core detection'**
  String get coreDetection;

  /// No description provided for @confidence.
  ///
  /// In en, this message translates to:
  /// **'Confidence'**
  String get confidence;

  /// No description provided for @reasons.
  ///
  /// In en, this message translates to:
  /// **'Reasons'**
  String get reasons;

  /// No description provided for @switchedNode.
  ///
  /// In en, this message translates to:
  /// **'Switched to {name}'**
  String switchedNode(String name);

  /// No description provided for @autoSwitched.
  ///
  /// In en, this message translates to:
  /// **'Auto-switched to {name}'**
  String autoSwitched(String name);

  /// No description provided for @nodeUnhealthy.
  ///
  /// In en, this message translates to:
  /// **'Node unhealthy'**
  String get nodeUnhealthy;

  /// No description provided for @subscriptionUpdated.
  ///
  /// In en, this message translates to:
  /// **'Subscription updated: {before} â†’ {after} nodes'**
  String subscriptionUpdated(int before, int after);

  /// No description provided for @coreCrashed.
  ///
  /// In en, this message translates to:
  /// **'Core crashed and is restarting'**
  String get coreCrashed;

  /// No description provided for @importSuccess.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} nodes'**
  String importSuccess(int count);

  /// No description provided for @importPartial.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} nodes, {skipped} skipped'**
  String importPartial(int count, int skipped);

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed'**
  String get importFailed;

  /// No description provided for @engineMissing.
  ///
  /// In en, this message translates to:
  /// **'Engine not installed'**
  String get engineMissing;

  /// No description provided for @engineMissingHint.
  ///
  /// In en, this message translates to:
  /// **'Place the {engine} binary in the cores folder or set its path in Settings.'**
  String engineMissingHint(String engine);

  /// No description provided for @quickSettings.
  ///
  /// In en, this message translates to:
  /// **'Quick Settings'**
  String get quickSettings;

  /// No description provided for @recommendedNodes.
  ///
  /// In en, this message translates to:
  /// **'Recommended Nodes'**
  String get recommendedNodes;

  /// No description provided for @tapToConnect.
  ///
  /// In en, this message translates to:
  /// **'Tap to connect'**
  String get tapToConnect;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @time.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get time;

  /// No description provided for @pillIranApps.
  ///
  /// In en, this message translates to:
  /// **'Iran Apps'**
  String get pillIranApps;

  /// No description provided for @pillAds.
  ///
  /// In en, this message translates to:
  /// **'Ads'**
  String get pillAds;

  /// No description provided for @pillProxyMode.
  ///
  /// In en, this message translates to:
  /// **'Proxy Mode'**
  String get pillProxyMode;

  /// No description provided for @pillTlsFragment.
  ///
  /// In en, this message translates to:
  /// **'Split HTTPS'**
  String get pillTlsFragment;

  /// No description provided for @modeTun.
  ///
  /// In en, this message translates to:
  /// **'TUN'**
  String get modeTun;

  /// No description provided for @modeProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get modeProxy;

  /// No description provided for @screeningSummary.
  ///
  /// In en, this message translates to:
  /// **'{xrayOnly} Xray-only nodes, {risky} with stream warnings'**
  String screeningSummary(Object risky, Object xrayOnly);

  /// No description provided for @clipboardAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add from clipboard?'**
  String get clipboardAddTitle;

  /// No description provided for @clipboardAddBody.
  ///
  /// In en, this message translates to:
  /// **'{count} share link(s) were detected in your clipboard. Add them to Atlanhix?'**
  String clipboardAddBody(Object count);

  /// No description provided for @clipboardAddNodes.
  ///
  /// In en, this message translates to:
  /// **'Add nodes'**
  String get clipboardAddNodes;

  /// No description provided for @clipboardAddSubscription.
  ///
  /// In en, this message translates to:
  /// **'Add subscription'**
  String get clipboardAddSubscription;

  /// No description provided for @clipboardLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get clipboardLater;

  /// No description provided for @warpOfferTitle.
  ///
  /// In en, this message translates to:
  /// **'Node looks filtered'**
  String get warpOfferTitle;

  /// No description provided for @warpOfferBody.
  ///
  /// In en, this message translates to:
  /// **'{node} did not answer {count} URL tests through the tunnel. Enable the WARP chain in front of it? (You can turn WARP off any time.)'**
  String warpOfferBody(Object count, Object node);

  /// No description provided for @warpOfferEnable.
  ///
  /// In en, this message translates to:
  /// **'Chain WARP'**
  String get warpOfferEnable;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
