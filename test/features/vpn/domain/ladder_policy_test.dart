import 'package:boltmesh/features/vpn/domain/ladder_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of the ladder table: the evidence a tick carries and the knobs that
/// decide what it may spend.
typedef Row = ({
  bool hasNetwork,
  bool? gateway,
  bool serverDown,
  bool lowerRung,
  bool canHeal,
  bool moveBudgetLeft,
  bool escalate,
});

/// Builds a row. [gateway] defaults to a single performed-dead echo, the
/// weakest local signal; the tri-state null (unprobeable) is spelled out by the
/// cells that care.
Row row({
  bool hasNetwork = true,
  bool? gateway = false,
  bool serverDown = false,
  bool lowerRung = true,
  bool canHeal = true,
  bool moveBudgetLeft = true,
  bool escalate = false,
}) => (
  hasNetwork: hasNetwork,
  gateway: gateway,
  serverDown: serverDown,
  lowerRung: lowerRung,
  canHeal: canHeal,
  moveBudgetLeft: moveBudgetLeft,
  escalate: escalate,
);

/// [Row] with the non-nullable axes replaced. Records have no literal spread,
/// so this is how a test pins one signal and varies the rest.
Row pin(
  Row r, {
  bool? hasNetwork,
  bool? serverDown,
  bool? lowerRung,
  bool? canHeal,
  bool? moveBudgetLeft,
  bool? escalate,
}) => (
  hasNetwork: hasNetwork ?? r.hasNetwork,
  gateway: r.gateway,
  serverDown: serverDown ?? r.serverDown,
  lowerRung: lowerRung ?? r.lowerRung,
  canHeal: canHeal ?? r.canHeal,
  moveBudgetLeft: moveBudgetLeft ?? r.moveBudgetLeft,
  escalate: escalate ?? r.escalate,
);

/// [Row] with the echo result replaced. Separate from [pin] because the echo is
/// tri-state and a `null` there means "unknown", not "unpinned".
Row withGateway(Row r, bool? gateway) => (
  hasNetwork: r.hasNetwork,
  gateway: gateway,
  serverDown: r.serverDown,
  lowerRung: r.lowerRung,
  canHeal: r.canHeal,
  moveBudgetLeft: r.moveBudgetLeft,
  escalate: r.escalate,
);

/// The local verdicts, kept as arguments rather than columns: they all mean
/// "this path is dead" and overlap, so a row never needs more than one. [hardStale]
/// is the uncorroborated 45s ceiling, [neverHandshake] the 30s verdict the
/// classifier honors only once the control plane has answered — the pair is the
/// cost-of-action distinction, so they get separate names rather than a column.
RecoveryStep local(
  Row r, {
  bool echoRun = false,
  bool hardStale = false,
  bool neverHandshake = false,
}) => decideLocalRecovery(
  hasNetwork: r.hasNetwork,
  gatewayAlive: r.gateway,
  serverConfirmedDown: r.serverDown,
  confirmedLocalPathDeath: echoRun,
  hardStalled: hardStale,
  neverHandshookPastGrace: neverHandshake,
  lowerRungAvailable: r.lowerRung,
  canHeal: r.canHeal,
  moveBudgetLeft: r.moveBudgetLeft,
);

RecoveryStep decided(
  Row r, {
  bool? api,
  bool echoRun = false,
  bool hardStale = false,
  bool neverHandshake = false,
}) => decideRecoveryStep(
  gatewayAlive: r.gateway,
  apiReachable: api,
  serverConfirmedDown: r.serverDown,
  confirmedLocalPathDeath: echoRun,
  hardStalled: hardStale,
  neverHandshookPastGrace: neverHandshake,
  lowerRungAvailable: r.lowerRung,
  canHeal: r.canHeal,
  moveBudgetLeft: r.moveBudgetLeft,
  escalateToMove: r.escalate,
);

/// What a local decision may return. Anything else means a tick acted on a cell
/// that should have gone to the control plane.
const _localOnly = {
  RecoveryStep.pauseNoNetwork,
  RecoveryStep.suppressLiveEcho,
  RecoveryStep.moveServer,
  RecoveryStep.probeControlPlane,
};

const _healSteps = {RecoveryStep.stepTransportRung, RecoveryStep.restartTunnel};

const _moveSteps = {RecoveryStep.moveServer, RecoveryStep.escalateToServer};

void main() {
  // The property this file exists for: the rung-before-move ordering is a
  // property of the *evidence*, so it is checked over the whole cross-product
  // rather than cell by cell. The named cells below then pin what production
  // actually reaches, so a future edit to the ladder has to keep reading the
  // same way or fail a named test.
  group('decideLocalRecovery', () {
    test('every evidence combination lands on a decidable step', () {
      for (final r in allRows()) {
        for (final echoRun in [false, true]) {
          for (final hardStale in [false, true]) {
            expect(
              _localOnly,
              contains(local(r, echoRun: echoRun, hardStale: hardStale)),
              reason: 'row=$r echoRun=$echoRun hardStale=$hardStale',
            );
          }
        }
      }
    });

    test('a down link freezes every other signal', () {
      for (final r in allRowsWith(hasNetwork: false)) {
        for (final gateway in [true, false, null]) {
          expect(
            local(withGateway(r, gateway)),
            RecoveryStep.pauseNoNetwork,
            reason: 'gateway=$gateway row=$r',
          );
        }
      }
    });

    test('a live echo never acts, whatever else the tick knows', () {
      // Except the backend's own verdict that the node is gone: there the echo
      // is a symptom read and the verdict is the cause, so a move still runs.
      for (final r in allRows()) {
        if (!r.hasNetwork) {
          expect(local(withGateway(r, true)), RecoveryStep.pauseNoNetwork);
          continue;
        }
        expect(
          local(withGateway(r, true)),
          r.serverDown
              ? (r.moveBudgetLeft
                    ? RecoveryStep.moveServer
                    : RecoveryStep.probeControlPlane)
              : RecoveryStep.suppressLiveEcho,
          reason: 'serverDown=${r.serverDown} row=$r',
        );
      }
    });

    test('a rung step is taken before a move, never after it', () {
      for (final r in allRowsWith(hasNetwork: true)) {
        for (final lowerRung in [true, false]) {
          for (final canHeal in [true, false]) {
            final cell = pin(r, lowerRung: lowerRung, canHeal: canHeal);
            if (r.gateway == true && !r.serverDown) {
              expect(local(cell), RecoveryStep.suppressLiveEcho);
              continue;
            }
            // Positive local evidence is the node verdict (an echo run and a
            // hard-stale handshake stand in for it in the cells below); with
            // the control plane deliberately unknown nothing else can read as a
            // dead path.
            final deadPath = r.serverDown;
            final rungStep = !r.serverDown && lowerRung && canHeal;
            expect(
              local(cell),
              deadPath && r.moveBudgetLeft && !rungStep
                  ? RecoveryStep.moveServer
                  : RecoveryStep.probeControlPlane,
              reason: 'lower=$lowerRung canHeal=$canHeal row=$r',
            );
          }
        }
      }
    });

    test('the node verdict skips a rung step an echo run would take', () {
      // Both are positive local evidence of a dead path, and they are identical
      // except in one place: an unattributed dead path can still step a rung
      // (the ladder's whole point), while the backend's own verdict that the
      // node is gone skips straight to moving servers. That is the difference
      // `!serverDown` inside the rung-step gate buys, so it is asserted here
      // rather than left to be re-read.
      for (final r in allRowsWith(hasNetwork: true, serverDown: false)) {
        if (r.gateway == true) continue;
        for (final lowerRung in [true, false]) {
          for (final canHeal in [true, false]) {
            final cell = pin(r, lowerRung: lowerRung, canHeal: canHeal);
            final rungStep = lowerRung && canHeal;
            expect(
              local(cell, echoRun: true) == local(pin(cell, serverDown: true)),
              // Equal exactly when no rung step was affordable to the echo run:
              // with one available it keeps the ladder, the verdict does not.
              !r.moveBudgetLeft || !rungStep,
              reason: 'lower=$lowerRung canHeal=$canHeal row=$r',
            );
          }
        }
      }
    });

    test('a spent move budget never takes the pre-probe fast-track', () {
      // Nothing is gained by stopping a tunnel on evidence the control plane
      // has not corroborated when the move itself could not run.
      for (final r in allRowsWith(moveBudgetLeft: false)) {
        for (final verdict in [
          local(r),
          local(r, echoRun: true),
          local(r, hardStale: true),
        ]) {
          expect(verdict, isNot(RecoveryStep.moveServer), reason: 'row=$r');
        }
      }
    });
  });

  group('decideRecoveryStep', () {
    test('a live echo suppresses even after the control plane answered', () {
      for (final api in [true, false, null]) {
        expect(
          decided(row(gateway: true), api: api),
          RecoveryStep.suppressLiveEcho,
        );
        // ...but not on top of the backend's dead-node verdict.
        expect(
          decided(row(gateway: true, serverDown: true), api: api),
          isNot(RecoveryStep.suppressLiveEcho),
        );
      }
    });

    test('a never-handshook verdict buys a rung step, never an uncorroborated move', () {
      // The cost-of-action rule, in both directions. This verdict is real local
      // evidence at 30s, but a fast-track move stops the tunnel and spends the
      // move budget without asking anyone, so that action is held to the later
      // uncorroborated ceiling ([hardStale]) instead. A rung step is a
      // same-server restart the control plane's answer licensed, so this
      // verdict is enough for it — and that is the gap: without it a
      // never-handshook spent its single heal on a same-rung restart and could
      // never be diagnosed as a blocked transport at all.
      // serverDown pinned off: the backend's node verdict is attributed and
      // fast-tracks on its own, with or without this handshake evidence.
      // escalate pinned off so the escalation gate does not outrank the rung
      // step under test.
      for (final r in allRowsWith(
        hasNetwork: true,
        canHeal: true,
        serverDown: false,
        escalate: false,
      ).where((r) => r.gateway != true)) {
        for (final lowerRung in [true, false]) {
          final cell = pin(r, lowerRung: lowerRung);
          expect(
            local(cell, neverHandshake: true),
            RecoveryStep.probeControlPlane,
            reason: 'no control-plane answer yet: row=$cell',
          );
          for (final api in [false, null]) {
            expect(
              decided(cell, api: api, neverHandshake: true),
              isNot(RecoveryStep.moveServer),
              reason: 'api=$api row=$cell',
            );
          }
        }
      }

      // With the control plane answering, this verdict is a confirmed dead
      // path, so the cheapest available action wins: a rung step where the
      // region serves one, the move where it does not. Only the unprobeable-echo
      // rows are asserted — a *performed-dead* echo already carries the same
      // information through its own rule, so there this verdict is moot.
      for (final r in allRowsWith(
        hasNetwork: true,
        canHeal: true,
        serverDown: false,
        escalate: false,
      ).where((r) => r.gateway == null)) {
        for (final lowerRung in [true, false]) {
          for (final moveBudgetLeft in [true, false]) {
            final cell = pin(
              r,
              lowerRung: lowerRung,
              moveBudgetLeft: moveBudgetLeft,
            );
            expect(
              decided(cell, api: true, neverHandshake: true),
              // Cheapest available action: the rung step where the region
              // serves one, the move where it does not but the budget allows,
              // and otherwise a plain rebuild — never a wait, since a heal is
              // affordable here.
              lowerRung
                  ? RecoveryStep.stepTransportRung
                  : moveBudgetLeft
                  ? RecoveryStep.moveServer
                  : RecoveryStep.restartTunnel,
              reason: 'row=$cell',
            );
          }
        }
      }
      // The uncorroborated ceiling is what does reach the move on its own.
      expect(
        decided(
          row(gateway: null, lowerRung: false),
          api: false,
          hardStale: true,
        ),
        RecoveryStep.moveServer,
      );
    });

    test(
      'a rung step needs a reachable control plane, cheap heal and a rung',
      () {
        for (final r in allRows()) {
          for (final api in [true, false, null]) {
            for (final lowerRung in [true, false]) {
              for (final canHeal in [true, false]) {
                final step = decided(
                  pin(r, lowerRung: lowerRung, canHeal: canHeal),
                  api: api,
                );
                if (step != RecoveryStep.stepTransportRung) continue;
                expect(api, isTrue, reason: 'row=$r lower=$lowerRung');
                expect(
                  canHeal && lowerRung && !r.serverDown,
                  isTrue,
                  reason: 'row=$r lower=$lowerRung canHeal=$canHeal',
                );
              }
            }
          }
        }
      },
    );

    test('the backend dead-node verdict never steps a rung', () {
      // The rung exists for a *transport* the network blocks. A node the
      // backend has given up on is not that, so the ladder is skipped.
      for (final api in [true, false, null]) {
        for (final lowerRung in [true, false]) {
          for (final canHeal in [true, false]) {
            expect(
              decided(
                pin(
                  row(serverDown: true),
                  lowerRung: lowerRung,
                  canHeal: canHeal,
                ),
                api: api,
                echoRun: true,
              ),
              isNot(RecoveryStep.stepTransportRung),
              reason: 'api=$api lower=$lowerRung canHeal=$canHeal',
            );
          }
        }
      }
    });

    test('a heal is never spent as a move', () {
      // The rung-before-move ordering in its sharpest form: a tick that heals
      // does not move, and a tick that moves does not demote a rung.
      for (final r in allRows()) {
        for (final api in [true, false, null]) {
          for (final verdict in [
            decided(r, api: api),
            decided(r, api: api, echoRun: true),
            decided(r, api: api, hardStale: true),
          ]) {
            if (_healSteps.contains(verdict)) {
              expect(_moveSteps, isNot(contains(verdict)));
            }
            if (verdict == RecoveryStep.stepTransportRung) {
              expect(_moveSteps, isNot(contains(verdict)));
            }
          }
        }
      }
    });

    test('a spent heal budget never heals again', () {
      for (final r in allRowsWith(canHeal: false)) {
        for (final api in [true, false, null]) {
          for (final verdict in [
            decided(r, api: api),
            decided(r, api: api, echoRun: true),
            decided(r, api: api, hardStale: true),
          ]) {
            expect(_healSteps, isNot(contains(verdict)), reason: 'api=$api');
          }
        }
      }
    });

    test(
      'an unreachable control plane never licenses a move or a demotion',
      () {
        // Discovery and the switch POST would only fail, and a demotion would
        // change transport on evidence that cannot tell blocked from gone.
        // `escalate` is pinned off because it is `shouldEscalateToFailover`'s
        // verdict, which already requires the control plane to have answered.
        for (final r in allRowsWith(escalate: false)) {
          for (final api in [false, null]) {
            for (final verdict in [
              decided(r, api: api),
              decided(r, api: api, echoRun: true),
            ]) {
              expect(
                verdict,
                isNot(
                  anyOf(
                    RecoveryStep.stepTransportRung,
                    RecoveryStep.escalateToServer,
                  ),
                ),
                reason: 'api=$api row=$r',
              );
            }
          }
        }
      },
    );

    test(
      'a terminal step needs both budgets spent and a live control plane',
      () {
        for (final r in allRows()) {
          for (final api in [true, false, null]) {
            for (final moveBudgetLeft in [true, false]) {
              for (final canHeal in [true, false]) {
                final verdict = decided(
                  pin(r, moveBudgetLeft: moveBudgetLeft, canHeal: canHeal),
                  api: api,
                );
                if (verdict != RecoveryStep.surfaceExhausted) continue;
                expect(api, isTrue);
                expect(moveBudgetLeft, isFalse);
                expect(canHeal, isFalse);
              }
            }
          }
        }
      },
    );

    test('a fast-track move needs the move budget and no rung step', () {
      for (final r in allRows()) {
        for (final api in [true, false, null]) {
          for (final verdict in [
            decided(r, api: api),
            decided(r, api: api, echoRun: true),
            decided(r, api: api, hardStale: true),
          ]) {
            if (verdict != RecoveryStep.moveServer) continue;
            expect(r.moveBudgetLeft, isTrue, reason: 'api=$api row=$r');
            // Never spend a move while a rung step was affordable: that is the
            // whole point of the ordering.
            expect(
              !(!r.serverDown && r.lowerRung && r.canHeal),
              isTrue,
              reason: 'api=$api row=$r',
            );
          }
        }
      }
    });
  });

  // The cells production reaches, named so a change to the ladder reads as a
  // change to a documented behaviour rather than as a silent diff.
  group('ladder cells', () {
    test('a blocked rung with the control plane up steps down one rung', () {
      // Item 1's regression, as a policy row: a confirmed dead echo run and a
      // stale handshake with the API answering is a blocked transport.
      expect(local(row(), echoRun: true), RecoveryStep.probeControlPlane);
      expect(
        decided(row(), api: true, echoRun: true),
        RecoveryStep.stepTransportRung,
      );
    });

    test('the same evidence during a blackout restarts on the same rung', () {
      // The control plane not answering is not evidence about *this*
      // transport, so the cheap restart still runs — in place.
      expect(local(row(), echoRun: true), RecoveryStep.probeControlPlane);
      for (final api in [false, null]) {
        expect(
          decided(row(), api: api, echoRun: true),
          RecoveryStep.restartTunnel,
          reason: 'api=$api',
        );
      }
    });

    test('a dead echo run with nowhere cheaper to go moves servers', () {
      // No lower rung: a heal would rebuild the same config on the same rung,
      // so the move budget is the cheaper recovery, not a wasted restart.
      expect(
        local(row(lowerRung: false), echoRun: true),
        RecoveryStep.moveServer,
      );
      expect(
        decided(row(lowerRung: false), api: true, echoRun: true),
        RecoveryStep.moveServer,
      );
    });

    test('a hard-stale handshake substitutes for an unprobeable echo', () {
      // The echo could not be performed at all (null), so the handshake ceiling
      // is the positive evidence. A blackout cannot demote on it; a reachable
      // control plane makes it a rung step.
      final unprobeable = row(gateway: null);
      expect(
        local(unprobeable, hardStale: true),
        RecoveryStep.probeControlPlane,
      );
      expect(
        decided(unprobeable, api: false, hardStale: true),
        RecoveryStep.restartTunnel,
      );
      expect(
        decided(unprobeable, api: true, hardStale: true),
        RecoveryStep.stepTransportRung,
      );
      // A never-completed handshake reaches the same verdict by the same route:
      // the ceiling it is measured against is the corroboration gate, so the
      // evidence exists on the tick the stall is first corroborated.
      expect(
        decided(unprobeable, api: true, hardStale: true),
        decided(row(gateway: null), api: true, echoRun: true),
      );
    });

    test('a stall that outlives a heal escalates to another server', () {
      // Heal spent, backend quiet, control plane answering: this is the
      // escalation, and unlike a fast-track it is not confirmed path death —
      // the caller passes no tunnel-path-dead evidence.
      expect(
        decided(row(gateway: null, canHeal: false, escalate: true), api: true),
        RecoveryStep.escalateToServer,
      );
    });

    test(
      'a spent heal budget with a quiet backend waits instead of moving',
      () {
        // Heal spent, move budget intact, escalation gate not met. Spending a
        // move on a stall that may not be a dead server is what this avoids.
        expect(
          decided(row(gateway: null, canHeal: false), api: true),
          RecoveryStep.verifyTunnel,
        );
        expect(
          decided(row(gateway: null, canHeal: false), api: false),
          RecoveryStep.waitForControlPlane,
        );
        // Both budgets spent with the control plane up is the terminal state.
        expect(
          decided(
            row(gateway: null, canHeal: false, moveBudgetLeft: false),
            api: true,
          ),
          RecoveryStep.surfaceExhausted,
        );
      },
    );

    test('a single dead echo needs the control plane before it acts', () {
      // One dropped DNS datagram is not path-death evidence on its own: with
      // the API answering it becomes a rung step (item 1's gate), and with a
      // lower rung available it is a demotion rather than a move.
      expect(local(row(lowerRung: false)), RecoveryStep.probeControlPlane);
      expect(decided(row(), api: true), RecoveryStep.stepTransportRung);
      expect(
        decided(row(lowerRung: false), api: true),
        RecoveryStep.moveServer,
      );
      for (final api in [false, null]) {
        expect(
          decided(row(lowerRung: false), api: api),
          RecoveryStep.restartTunnel,
          reason: 'api=$api',
        );
      }
    });
  });
}

/// Every combination of the decision's inputs.
Iterable<Row> allRows() sync* {
  for (final hasNetwork in [true, false]) {
    for (final gateway in [true, false, null]) {
      for (final serverDown in [true, false]) {
        for (final lowerRung in [true, false]) {
          for (final canHeal in [true, false]) {
            for (final moveBudgetLeft in [true, false]) {
              for (final escalate in [true, false]) {
                yield row(
                  hasNetwork: hasNetwork,
                  gateway: gateway,
                  serverDown: serverDown,
                  lowerRung: lowerRung,
                  canHeal: canHeal,
                  moveBudgetLeft: moveBudgetLeft,
                  escalate: escalate,
                );
              }
            }
          }
        }
      }
    }
  }
}

/// [allRows] with one axis pinned, so a group can state the signal it is about
/// and let the rest vary.
Iterable<Row> allRowsWith({
  bool? hasNetwork,
  bool? serverDown,
  bool? lowerRung,
  bool? canHeal,
  bool? moveBudgetLeft,
  bool? escalate,
}) sync* {
  for (final r in allRows()) {
    yield pin(
      r,
      hasNetwork: hasNetwork,
      serverDown: serverDown,
      lowerRung: lowerRung,
      canHeal: canHeal,
      moveBudgetLeft: moveBudgetLeft,
      escalate: escalate,
    );
  }
}
