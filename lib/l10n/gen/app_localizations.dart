import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
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

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
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
    Locale('de'),
    Locale('en'),
  ];

  /// App bar title across Home, login and shell.
  ///
  /// In en, this message translates to:
  /// **'BoltMesh VPN'**
  String get appTitle;

  /// Bottom navigation tab: connect screen.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get navConnect;

  /// Bottom navigation tab: region list.
  ///
  /// In en, this message translates to:
  /// **'Regions'**
  String get navRegions;

  /// Bottom navigation tab: settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Heading when the tunnel is up without a server name.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get homeStatusConnected;

  /// Heading when the tunnel is up with a server name.
  ///
  /// In en, this message translates to:
  /// **'Connected · {server}'**
  String homeStatusConnectedTo(String server);

  /// Heading when the tunnel is down.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get homeStatusDisconnected;

  /// Heading when the last operation failed.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get homeStatusError;

  /// Fallback plan name when the backend returns none.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get homePlanFallback;

  /// Plan line without an expiry date.
  ///
  /// In en, this message translates to:
  /// **'{plan}'**
  String homePlanOnly(String plan);

  /// Plan line with a locale-formatted renewal date.
  ///
  /// In en, this message translates to:
  /// **'{plan} · renews {date}'**
  String homePlanRenews(String plan, String date);

  /// Hero power button label when disconnected.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get homeConnect;

  /// Hero power button label when connected.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get homeDisconnect;

  /// Semantics hint for the connect hero button.
  ///
  /// In en, this message translates to:
  /// **'Starts the VPN tunnel'**
  String get homeConnectHint;

  /// Semantics hint for the disconnect hero button.
  ///
  /// In en, this message translates to:
  /// **'Stops the VPN tunnel'**
  String get homeDisconnectHint;

  /// Semantics label for the in-progress spinner.
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get homeWorking;

  /// Banner on the disconnected Home when the control-plane probe fails; the Connect button is disabled alongside it.
  ///
  /// In en, this message translates to:
  /// **'Backend unreachable. Connect is disabled until the server is reachable.'**
  String get homeBackendUnreachable;

  /// Title above the download/upload counters.
  ///
  /// In en, this message translates to:
  /// **'Session traffic'**
  String get homeTrafficTitle;

  /// Visible traffic counters; values are pre-formatted byte strings.
  ///
  /// In en, this message translates to:
  /// **'Download {down} · Upload {up}'**
  String homeTrafficLabel(String down, String up);

  /// Screen-reader label for the traffic counters.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {down}, uploaded {up}'**
  String homeTrafficSemantics(String down, String up);

  /// Debug traffic line in Settings; values are pre-formatted byte strings.
  ///
  /// In en, this message translates to:
  /// **'Traffic RX {rx} · TX {tx}'**
  String settingsTrafficLabel(String rx, String tx);

  /// Login screen heading and submit button label.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get loginTitle;

  /// Snack shown when the login form is submitted empty.
  ///
  /// In en, this message translates to:
  /// **'Enter your username and password.'**
  String get loginValidationEmpty;

  /// Label for the login identifier field.
  ///
  /// In en, this message translates to:
  /// **'Username or email'**
  String get loginIdentifierLabel;

  /// Hint for the login identifier field.
  ///
  /// In en, this message translates to:
  /// **'johndoe or john@example.com'**
  String get loginIdentifierHint;

  /// Label for the login password field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPasswordLabel;

  /// Tooltip/semantics label for the password visibility toggle when hidden.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get loginShowPassword;

  /// Tooltip/semantics label for the password visibility toggle when shown.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get loginHidePassword;

  /// Divider between password login and OAuth buttons.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get loginOr;

  /// OAuth sign-in button for Google.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get loginGoogle;

  /// OAuth sign-in button for GitHub.
  ///
  /// In en, this message translates to:
  /// **'Continue with GitHub'**
  String get loginGithub;

  /// Hint for the region list search field.
  ///
  /// In en, this message translates to:
  /// **'Search regions or servers'**
  String get regionsSearchHint;

  /// Region list loading failure. Never interpolates a raw exception.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load regions. Check your connection and try again.'**
  String get regionsLoadError;

  /// Generic retry action for a failed load.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// Title for the automatic lowest-load connection row.
  ///
  /// In en, this message translates to:
  /// **'Quick Connect (Auto)'**
  String get regionsQuickConnect;

  /// Subtitle when no region has dialable capacity.
  ///
  /// In en, this message translates to:
  /// **'No capacity right now'**
  String get regionsNoCapacity;

  /// Subtitle naming the automatic region pick.
  ///
  /// In en, this message translates to:
  /// **'Lowest-load region: {name}'**
  String regionsLowestLoad(String name);

  /// Empty search result in the region list.
  ///
  /// In en, this message translates to:
  /// **'No regions match your search.'**
  String get regionsNoMatch;

  /// Region subtitle with server and peer counts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 server} other{{count} servers}} · {peers, plural, =1{1 peer} other{{peers} peers}}'**
  String regionsServerCount(int count, int peers);

  /// Server row subtitle with endpoint and peer count.
  ///
  /// In en, this message translates to:
  /// **'{endpoint}:{port} · {peers, plural, =1{1 peer} other{{peers} peers}}'**
  String regionsServerSubtitle(String endpoint, int port, int peers);

  /// Footer shown while a server switch is in progress.
  ///
  /// In en, this message translates to:
  /// **'Switching…'**
  String get regionsSwitching;

  /// Tooltip for the region list refresh button.
  ///
  /// In en, this message translates to:
  /// **'Refresh regions'**
  String get regionsRefresh;

  /// Snack after a manual region list refresh succeeds.
  ///
  /// In en, this message translates to:
  /// **'Regions updated ({count} regions)'**
  String regionsRefreshed(int count);

  /// Account header in Settings.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {username}'**
  String settingsSignedInAs(String username);

  /// Fallback when no display name is known.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get settingsUnknownUser;

  /// Sign-out button in Settings.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get settingsLogOut;

  /// Label above the device name field.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get settingsDeviceNameLabel;

  /// Hint for the device name field.
  ///
  /// In en, this message translates to:
  /// **'BoltMesh Device'**
  String get settingsDeviceNameHint;

  /// Snack when saving an empty device name.
  ///
  /// In en, this message translates to:
  /// **'Enter a device name first.'**
  String get settingsEnterNameFirst;

  /// Snack after the device name is stored.
  ///
  /// In en, this message translates to:
  /// **'Device name saved'**
  String get settingsDeviceNameSaved;

  /// Button storing the device name.
  ///
  /// In en, this message translates to:
  /// **'Save name'**
  String get settingsSaveName;

  /// Title of the forget-device confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Forget device?'**
  String get settingsForgetTitle;

  /// Body of the forget-device confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'The next connect will provision a new device. Use this if the server no longer knows this device.'**
  String get settingsForgetBody;

  /// Dialog cancel action.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsCancel;

  /// Dialog confirm action for forgetting the device.
  ///
  /// In en, this message translates to:
  /// **'Forget'**
  String get settingsForget;

  /// Snack after the device identity is cleared.
  ///
  /// In en, this message translates to:
  /// **'Device cleared. Next connect reprovisions.'**
  String get settingsDeviceCleared;

  /// Button opening the forget-device dialog.
  ///
  /// In en, this message translates to:
  /// **'Forget device'**
  String get settingsForgetButton;

  /// Notice shown when the API targets localhost.
  ///
  /// In en, this message translates to:
  /// **'This API points at localhost (often a forwarded port). It becomes unreachable once the VPN tunnel is up — for VPN testing use a LAN/direct URL instead. Disconnect still tears the tunnel down locally when the server is unreachable.'**
  String get settingsLoopbackNotice;

  /// Title of the split-tunnel switch in Settings.
  ///
  /// In en, this message translates to:
  /// **'Allow Local Network Access'**
  String get settingsAllowLanTitle;

  /// Subtitle of the split-tunnel switch in Settings.
  ///
  /// In en, this message translates to:
  /// **'Keep printers, smart-home devices and LAN servers reachable. Turn off to force everything through the VPN (strict kill switch).'**
  String get settingsAllowLanSubtitle;

  /// Snack after the LAN toggle is flipped while connected.
  ///
  /// In en, this message translates to:
  /// **'Network setting applied. Tunnel restarted.'**
  String get settingsAllowLanApplied;

  /// Snack after the LAN toggle is flipped while disconnected.
  ///
  /// In en, this message translates to:
  /// **'Network setting saved. Applies on next connect.'**
  String get settingsAllowLanSaved;

  /// Subtitle of the LAN toggle while its saved value is loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get settingsAllowLanLoading;

  /// Subtitle of the LAN toggle when its saved value failed to load.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the current setting.'**
  String get settingsAllowLanError;

  /// Diagnostics placeholder for an unobserved tunnel stage.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get settingsDiagnosticsUnknown;

  /// Diagnostics placeholder for a status poll that never ran.
  ///
  /// In en, this message translates to:
  /// **'never'**
  String get settingsDiagnosticsNever;

  /// Diagnostics age of the last successful status poll.
  ///
  /// In en, this message translates to:
  /// **'{seconds}s ago'**
  String settingsDiagnosticsAgo(int seconds);

  /// Debug footer API base URL and platform line.
  ///
  /// In en, this message translates to:
  /// **'API: {api} · Platform: {platform}'**
  String settingsDiagnosticsApi(String api, String platform);

  /// Debug footer live tunnel snapshot.
  ///
  /// In en, this message translates to:
  /// **'Tunnel: stage {stage} · status {status} · failures {failures}'**
  String settingsDiagnosticsTunnel(String stage, String status, int failures);
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
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
