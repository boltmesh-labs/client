import 'package:boltmesh/core/desktop/tray_menu.dart';
import 'package:flutter_test/flutter_test.dart';

const _labels = TrayLabels(
  tooltip: 'BoltMesh VPN',
  show: 'Show BoltMesh',
  hide: 'Hide BoltMesh',
  connect: 'Connect',
  disconnect: 'Disconnect',
  quit: 'Quit',
);

TrayPresentation build({
  bool authenticated = true,
  bool connected = false,
  bool busy = false,
  bool windowVisible = true,
}) => buildTrayPresentation(
  labels: _labels,
  authenticated: authenticated,
  connected: connected,
  busy: busy,
  windowVisible: windowVisible,
);

TrayMenuEntry entryFor(TrayPresentation p, TrayAction action) =>
    p.entries.firstWhere((e) => e.action == action);

void main() {
  group('buildTrayPresentation', () {
    test('carries the localized tooltip', () {
      expect(build().tooltip, 'BoltMesh VPN');
    });

    test('visible window offers Hide, hidden offers Show', () {
      final shown = build();
      expect(shown.windowVisible, isTrue);
      expect(shown.entries.first.action, TrayAction.hide);
      expect(shown.entries.first.label, 'Hide BoltMesh');

      final hidden = build(windowVisible: false);
      expect(hidden.windowVisible, isFalse);
      expect(hidden.entries.first.action, TrayAction.show);
      expect(hidden.entries.first.label, 'Show BoltMesh');
    });

    test('signed in and idle offers Connect, enabled', () {
      final entry = entryFor(build(), TrayAction.connect);
      expect(entry.label, 'Connect');
      expect(entry.enabled, isTrue);
    });

    test('connected offers Disconnect instead of Connect', () {
      final p = build(connected: true);
      expect(entryFor(p, TrayAction.disconnect).enabled, isTrue);
      expect(p.entries.where((e) => e.action == TrayAction.connect), isEmpty);
    });

    test('an in-flight operation disables the connection toggle', () {
      expect(entryFor(build(busy: true), TrayAction.connect).enabled, isFalse);
      expect(
        entryFor(
          build(connected: true, busy: true),
          TrayAction.disconnect,
        ).enabled,
        isFalse,
      );
    });

    test('signed out omits the connection toggle entirely', () {
      final p = build(authenticated: false);
      expect(
        p.entries.where(
          (e) =>
              e.action == TrayAction.connect ||
              e.action == TrayAction.disconnect,
        ),
        isEmpty,
      );
      // Show/Hide, separator, Quit.
      expect(p.entries, hasLength(3));
      expect(p.entries[1].isSeparator, isTrue);
      expect(p.entries.last.action, TrayAction.quit);
    });

    test('Quit is always the last row', () {
      for (final authenticated in [true, false]) {
        final p = build(authenticated: authenticated);
        expect(p.entries.last.action, TrayAction.quit);
        expect(p.entries.last.label, 'Quit');
      }
    });

    test('TrayLabels compare by value so unchanged locales skip a rebuild', () {
      expect(_labels, _labels);
      expect(_labels.hashCode, _labels.hashCode);
      const translate = TrayLabels(
        tooltip: 'BoltMesh VPN',
        show: 'Anzeigen',
        hide: 'Ausblenden',
        connect: 'Verbinden',
        disconnect: 'Trennen',
        quit: 'Beenden',
      );
      expect(_labels == translate, isFalse);
      expect(_labels == Object(), isFalse);
    });
  });
}
