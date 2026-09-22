/// Tray-menu model plus the pure policy that turns app state into that menu.
///
/// Kept free of Flutter, Riverpod, l10n and native imports so the ordering,
/// wording and enablement rules are unit-testable without a platform channel.
/// The `TrayPlatform` glue and the `DesktopTray` coordinator stay thin on top.
library;

/// A selectable tray-menu action.
enum TrayAction { show, hide, connect, disconnect, quit }

/// One row in the tray menu: an [action] with a [label], or a separator.
class TrayMenuEntry {
  /// An actionable row. A null [label] never reaches the platform, but the
  /// field stays nullable so the separator form can share the shape.
  const TrayMenuEntry.action(this.action, this.label, {this.enabled = true})
    : isSeparator = false;

  /// A non-interactive divider.
  const TrayMenuEntry.separator()
    : action = null,
      label = null,
      enabled = false,
      isSeparator = true;

  /// Action dispatched when this row is picked (null for a separator).
  final TrayAction? action;

  /// Visible text (localized; null for a separator).
  final String? label;

  /// When false the row renders greyed out and ignores clicks.
  final bool enabled;

  /// True for a divider row.
  final bool isSeparator;
}

/// Everything the platform needs to render the tray after a state change.
class TrayPresentation {
  const TrayPresentation({
    required this.tooltip,
    required this.windowVisible,
    required this.entries,
  });

  /// Hover tooltip on the tray icon.
  final String tooltip;

  /// Whether the app window is currently shown; drives the toggle row.
  final bool windowVisible;

  /// Menu rows, top to bottom.
  final List<TrayMenuEntry> entries;
}

/// Localized strings the tray menu needs.
class TrayLabels {
  const TrayLabels({
    required this.tooltip,
    required this.show,
    required this.hide,
    required this.connect,
    required this.disconnect,
    required this.quit,
  });

  final String tooltip;
  final String show;
  final String hide;
  final String connect;
  final String disconnect;
  final String quit;

  @override
  bool operator ==(Object other) =>
      other is TrayLabels &&
      other.tooltip == tooltip &&
      other.show == show &&
      other.hide == hide &&
      other.connect == connect &&
      other.disconnect == disconnect &&
      other.quit == quit;

  @override
  int get hashCode =>
      Object.hash(tooltip, show, hide, connect, disconnect, quit);
}

/// Menu policy: a Show/Hide toggle, a Connect/Disconnect toggle for a
/// signed-in user, then Quit.
///
/// The connection toggle is omitted entirely while signed out (the login
/// screen owns that flow) and disabled while a connect/switch is already in
/// flight, so the tray can never queue a second operation behind the
/// controller's mutex.
TrayPresentation buildTrayPresentation({
  required TrayLabels labels,
  required bool authenticated,
  required bool connected,
  required bool busy,
  required bool windowVisible,
}) {
  final entries = <TrayMenuEntry>[
    if (windowVisible)
      TrayMenuEntry.action(TrayAction.hide, labels.hide)
    else
      TrayMenuEntry.action(TrayAction.show, labels.show),
    if (authenticated)
      connected
          ? TrayMenuEntry.action(
              TrayAction.disconnect,
              labels.disconnect,
              enabled: !busy,
            )
          : TrayMenuEntry.action(
              TrayAction.connect,
              labels.connect,
              enabled: !busy,
            ),
    const TrayMenuEntry.separator(),
    TrayMenuEntry.action(TrayAction.quit, labels.quit),
  ];
  return TrayPresentation(
    tooltip: labels.tooltip,
    windowVisible: windowVisible,
    entries: entries,
  );
}
