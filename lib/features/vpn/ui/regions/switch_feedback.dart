import 'package:flutter/material.dart';

import '../../state/vpn_providers.dart';

/// Surfaces a just-finished connect/switch/Quick Connect attempt: a failed
/// attempt snacks so the tap is never silently dead. Driven by the structured
/// [ConnState.opFailed]/[ConnPhase.error] signal, not by matching the
/// (localizable) wording of [ConnState.message]. Success and benign no-ops
/// (`Already on …`) stay silent. Disconnect is intentionally excluded: its
/// local teardown always succeeds, so it never calls this.
void showSwitchFeedback(BuildContext context, ConnState conn) {
  if (conn.message.isEmpty) return;
  if (conn.phase != ConnPhase.error && !conn.opFailed) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(conn.message)));
}
