// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'BoltMesh VPN';

  @override
  String get navConnect => 'Verbinden';

  @override
  String get navRegions => 'Regionen';

  @override
  String get navSettings => 'Einstellungen';

  @override
  String get homeStatusConnected => 'Verbunden';

  @override
  String homeStatusConnectedTo(String server) {
    return 'Verbunden · $server';
  }

  @override
  String get homeStatusDisconnected => 'Getrennt';

  @override
  String get homeStatusError => 'Fehler';

  @override
  String get homePlanFallback => 'Tarif';

  @override
  String homePlanOnly(String plan) {
    return '$plan';
  }

  @override
  String homePlanRenews(String plan, String date) {
    return '$plan · verlängert $date';
  }

  @override
  String get homeConnect => 'Verbinden';

  @override
  String get homeDisconnect => 'Trennen';

  @override
  String get homeConnectHint => 'Startet den VPN-Tunnel';

  @override
  String get homeDisconnectHint => 'Stoppt den VPN-Tunnel';

  @override
  String get homeWorking => 'Wird ausgeführt …';

  @override
  String get homeBackendUnreachable =>
      'Backend nicht erreichbar. Verbinden ist deaktiviert, bis der Server wieder erreichbar ist.';

  @override
  String get homeBackendUnreachableConnected =>
      'Backend nicht erreichbar. Der Tunnel bleibt bestehen, während die Wiederherstellung versucht wird.';

  @override
  String get homeAuthExpired =>
      'Sitzung abgelaufen. Melde dich erneut an, um die Verbindung wiederherzustellen.';

  @override
  String get homeSubscriptionInactive =>
      'Kein aktives Abo. Verlängere es, um dich wieder zu verbinden.';

  @override
  String get homeBackendError =>
      'Backend-Fehler. Wiederherstellung wird beobachtet …';

  @override
  String get homeTrafficTitle => 'Sitzungsdaten';

  @override
  String homeTrafficLabel(String down, String up) {
    return 'Download $down · Upload $up';
  }

  @override
  String homeTrafficSemantics(String down, String up) {
    return '$down heruntergeladen, $up hochgeladen';
  }

  @override
  String settingsTrafficLabel(String rx, String tx) {
    return 'Datenverkehr RX $rx · TX $tx';
  }

  @override
  String get loginTitle => 'Anmelden';

  @override
  String get loginValidationEmpty =>
      'Gib deinen Benutzernamen und dein Passwort ein.';

  @override
  String get loginIdentifierLabel => 'Benutzername oder E-Mail';

  @override
  String get loginIdentifierHint => 'maxmustermann oder max@example.com';

  @override
  String get loginPasswordLabel => 'Passwort';

  @override
  String get loginShowPassword => 'Passwort anzeigen';

  @override
  String get loginHidePassword => 'Passwort verbergen';

  @override
  String get loginOr => 'oder';

  @override
  String get loginGoogle => 'Mit Google fortfahren';

  @override
  String get loginGithub => 'Mit GitHub fortfahren';

  @override
  String get regionsSearchHint => 'Regionen oder Server suchen';

  @override
  String get regionsLoadError =>
      'Regionen konnten nicht geladen werden. Prüfe deine Verbindung und versuche es erneut.';

  @override
  String get commonRetry => 'Erneut versuchen';

  @override
  String get regionsQuickConnect => 'Schnellverbindung (Auto)';

  @override
  String get regionsNoCapacity => 'Gerade keine Kapazität';

  @override
  String regionsLowestLoad(String name) {
    return 'Region mit niedrigster Last: $name';
  }

  @override
  String get regionsNoMatch => 'Keine Regionen für diese Suche.';

  @override
  String regionsServerCount(int count, int peers) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Server',
      one: '1 Server',
    );
    String _temp1 = intl.Intl.pluralLogic(
      peers,
      locale: localeName,
      other: '$peers Peers',
      one: '1 Peer',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String regionsServerSubtitle(String endpoint, int port, int peers) {
    String _temp0 = intl.Intl.pluralLogic(
      peers,
      locale: localeName,
      other: '$peers Peers',
      one: '1 Peer',
    );
    return '$endpoint:$port · $_temp0';
  }

  @override
  String get regionsSwitching => 'Wechsle …';

  @override
  String get regionsRefresh => 'Regionen aktualisieren';

  @override
  String regionsRefreshed(int count) {
    return 'Regionen aktualisiert ($count Regionen)';
  }

  @override
  String settingsSignedInAs(String username) {
    return 'Angemeldet als $username';
  }

  @override
  String get settingsUnknownUser => 'unbekannt';

  @override
  String get settingsLogOut => 'Abmelden';

  @override
  String get settingsDeviceNameLabel => 'Gerätename';

  @override
  String get settingsDeviceNameHint => 'BoltMesh Device';

  @override
  String get settingsEnterNameFirst => 'Gib zuerst einen Gerätenamen ein.';

  @override
  String settingsDeviceNameTooLong(int max) {
    return 'Der Gerätename darf höchstens $max Zeichen lang sein.';
  }

  @override
  String get settingsDeviceNameSaved => 'Gerätename gespeichert';

  @override
  String get settingsSaveName => 'Name speichern';

  @override
  String get settingsForgetTitle => 'Gerät vergessen?';

  @override
  String get settingsForgetBody =>
      'Beim nächsten Verbinden wird ein neues Gerät provisioniert. Nutze dies, wenn der Server dieses Gerät nicht mehr kennt.';

  @override
  String get settingsCancel => 'Abbrechen';

  @override
  String get settingsForget => 'Vergessen';

  @override
  String get settingsDeviceCleared =>
      'Gerät entfernt. Beim nächsten Verbinden wird neu provisioniert.';

  @override
  String get settingsForgetButton => 'Gerät vergessen';

  @override
  String get settingsLoopbackNotice =>
      'Diese API zeigt auf localhost (oft ein weitergeleiteter Port). Sie wird unerreichbar, sobald der VPN-Tunnel steht — nutze für VPN-Tests stattdessen eine LAN-/direkte URL. Trennen reißt den Tunnel auch bei unerreichbarem Server lokal ab.';

  @override
  String get settingsAllowLanTitle => 'Lokales Netzwerk erlauben';

  @override
  String get settingsAllowLanSubtitle =>
      'Drucker, Smart-Home-Geräte und LAN-Server erreichbar lassen. Deaktivieren, um alles durch das VPN zu zwingen (strikter Kill-Switch).';

  @override
  String get settingsAllowLanApplied =>
      'Netzwerkeinstellung übernommen. Tunnel neu gestartet.';

  @override
  String get settingsAllowLanSaved =>
      'Netzwerkeinstellung gespeichert. Gilt ab der nächsten Verbindung.';

  @override
  String get settingsAllowLanLoading => 'Wird geladen …';

  @override
  String get settingsAllowLanError =>
      'Die aktuelle Einstellung konnte nicht gelesen werden.';

  @override
  String get settingsDiagnosticsUnknown => 'unbekannt';

  @override
  String get settingsDiagnosticsNever => 'nie';

  @override
  String settingsDiagnosticsAgo(int seconds) {
    return 'vor ${seconds}s';
  }

  @override
  String settingsDiagnosticsApi(String api, String platform) {
    return 'API: $api · Plattform: $platform';
  }

  @override
  String settingsDiagnosticsTunnel(String stage, String status, int failures) {
    return 'Tunnel: Status $stage · Statusabfrage $status · Fehler $failures';
  }

  @override
  String settingsDiagnosticsBackend(String issue) {
    return 'Backend-Problem: $issue';
  }

  @override
  String get trayShow => 'BoltMesh anzeigen';

  @override
  String get trayHide => 'BoltMesh ausblenden';

  @override
  String get trayConnect => 'Verbinden';

  @override
  String get trayDisconnect => 'Trennen';

  @override
  String get trayQuit => 'Beenden';
}
