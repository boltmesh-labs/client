// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'BoltMesh VPN';

  @override
  String get navConnect => 'Connect';

  @override
  String get navRegions => 'Regions';

  @override
  String get navSettings => 'Settings';

  @override
  String get homeStatusConnected => 'Connected';

  @override
  String homeStatusConnectedTo(String server) {
    return 'Connected · $server';
  }

  @override
  String get homeStatusDisconnected => 'Disconnected';

  @override
  String get homeStatusError => 'Error';

  @override
  String get homePlanFallback => 'Plan';

  @override
  String homePlanOnly(String plan) {
    return '$plan';
  }

  @override
  String homePlanRenews(String plan, String date) {
    return '$plan · renews $date';
  }

  @override
  String get homeConnect => 'Connect';

  @override
  String get homeDisconnect => 'Disconnect';

  @override
  String get homeConnectHint => 'Starts the VPN tunnel';

  @override
  String get homeDisconnectHint => 'Stops the VPN tunnel';

  @override
  String get homeWorking => 'Working…';

  @override
  String get homeBackendUnreachable =>
      'Backend unreachable. Connect is disabled until the server is reachable.';

  @override
  String get homeBackendUnreachableConnected =>
      'Backend unreachable. The tunnel stays up while recovery is attempted.';

  @override
  String get homeAuthExpired => 'Session expired. Log in again to reconnect.';

  @override
  String get homeSubscriptionInactive =>
      'No active subscription. Renew to reconnect.';

  @override
  String get homeBackendError => 'Backend error. Watching for recovery…';

  @override
  String get homeTrafficTitle => 'Session traffic';

  @override
  String homeTrafficLabel(String down, String up) {
    return 'Download $down · Upload $up';
  }

  @override
  String homeTrafficSemantics(String down, String up) {
    return 'Downloaded $down, uploaded $up';
  }

  @override
  String settingsTrafficLabel(String rx, String tx) {
    return 'Traffic RX $rx · TX $tx';
  }

  @override
  String get loginTitle => 'Log in';

  @override
  String get loginValidationEmpty => 'Enter your username and password.';

  @override
  String get loginIdentifierLabel => 'Username or email';

  @override
  String get loginIdentifierHint => 'johndoe or john@example.com';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginShowPassword => 'Show password';

  @override
  String get loginHidePassword => 'Hide password';

  @override
  String get loginOr => 'or';

  @override
  String get loginGoogle => 'Continue with Google';

  @override
  String get loginGithub => 'Continue with GitHub';

  @override
  String get regionsSearchHint => 'Search regions or servers';

  @override
  String get regionsLoadError =>
      'Couldn\'t load regions. Check your connection and try again.';

  @override
  String get commonRetry => 'Retry';

  @override
  String get regionsQuickConnect => 'Quick Connect (Auto)';

  @override
  String get regionsNoCapacity => 'No capacity right now';

  @override
  String regionsLowestLoad(String name) {
    return 'Lowest-load region: $name';
  }

  @override
  String get regionsNoMatch => 'No regions match your search.';

  @override
  String regionsServerCount(int count, int peers) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servers',
      one: '1 server',
    );
    String _temp1 = intl.Intl.pluralLogic(
      peers,
      locale: localeName,
      other: '$peers peers',
      one: '1 peer',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String regionsServerSubtitle(String endpoint, int port, int peers) {
    String _temp0 = intl.Intl.pluralLogic(
      peers,
      locale: localeName,
      other: '$peers peers',
      one: '1 peer',
    );
    return '$endpoint:$port · $_temp0';
  }

  @override
  String get regionsSwitching => 'Switching…';

  @override
  String get regionsRefresh => 'Refresh regions';

  @override
  String regionsRefreshed(int count) {
    return 'Regions updated ($count regions)';
  }

  @override
  String settingsSignedInAs(String username) {
    return 'Signed in as $username';
  }

  @override
  String get settingsUnknownUser => 'unknown';

  @override
  String get settingsLogOut => 'Log out';

  @override
  String get settingsDeviceNameLabel => 'Device name';

  @override
  String get settingsDeviceNameHint => 'BoltMesh Device';

  @override
  String get settingsEnterNameFirst => 'Enter a device name first.';

  @override
  String get settingsDeviceNameSaved => 'Device name saved';

  @override
  String get settingsSaveName => 'Save name';

  @override
  String get settingsForgetTitle => 'Forget device?';

  @override
  String get settingsForgetBody =>
      'The next connect will provision a new device. Use this if the server no longer knows this device.';

  @override
  String get settingsCancel => 'Cancel';

  @override
  String get settingsForget => 'Forget';

  @override
  String get settingsDeviceCleared =>
      'Device cleared. Next connect reprovisions.';

  @override
  String get settingsForgetButton => 'Forget device';

  @override
  String get settingsLoopbackNotice =>
      'This API points at localhost (often a forwarded port). It becomes unreachable once the VPN tunnel is up — for VPN testing use a LAN/direct URL instead. Disconnect still tears the tunnel down locally when the server is unreachable.';

  @override
  String get settingsAllowLanTitle => 'Allow Local Network Access';

  @override
  String get settingsAllowLanSubtitle =>
      'Keep printers, smart-home devices and LAN servers reachable. Turn off to force everything through the VPN (strict kill switch).';

  @override
  String get settingsAllowLanApplied =>
      'Network setting applied. Tunnel restarted.';

  @override
  String get settingsAllowLanSaved =>
      'Network setting saved. Applies on next connect.';

  @override
  String get settingsAllowLanLoading => 'Loading…';

  @override
  String get settingsAllowLanError => 'Couldn\'t read the current setting.';

  @override
  String get settingsDiagnosticsUnknown => 'unknown';

  @override
  String get settingsDiagnosticsNever => 'never';

  @override
  String settingsDiagnosticsAgo(int seconds) {
    return '${seconds}s ago';
  }

  @override
  String settingsDiagnosticsApi(String api, String platform) {
    return 'API: $api · Platform: $platform';
  }

  @override
  String settingsDiagnosticsTunnel(String stage, String status, int failures) {
    return 'Tunnel: stage $stage · status $status · failures $failures';
  }

  @override
  String settingsDiagnosticsBackend(String issue) {
    return 'Backend issue: $issue';
  }
}
