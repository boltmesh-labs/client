import '../../../core/log.dart';
import '../data/helper_client.dart' show capStreamTransport;
import '../data/models.dart';
import '../data/platform_info.dart';
import '../data/stream_transport.dart';

/// The transport ladder.
///
/// The serving node advertises which rungs it runs, in cost order (see
/// [TransportOption]), and where the walk *starts* is the cheapest rung on that
/// list this platform can run (see [rungFor]). So a node serving both stock and
/// obfuscated starts stock and demotes, rather than being treated as a
/// single-format node with one option — and a node that serves only `awg` and
/// `stream` floors a platform with no obfuscated data plane to `stream` rather
/// than refusing it.
///
/// This is the process's rung *state* plus the pure rules that read and move it
/// (which rung is the floor, which rung is next, what config each rung implies).
/// It was an extension over the controller because it moved with the
/// connect/switch/heal flow; it is a collaborator because none of that logic
/// needs the notifier — only the two ambient inputs it is constructed with
/// (the platform/helper capability gate and the e2e force seam).
///
/// The demotion rides the existing heal rung — `_autoHeal` already restarts the
/// cached config offline, which is exactly the moment a fingerprint-blocked path
/// should be retried on a lower rung. It is licensed by local path-death
/// evidence alone, not the control plane: in a full tunnel the probe is routed
/// through the very rung that is dead, so requiring it made the step
/// unreachable exactly when it is needed. It costs no polling timer and no
/// budget of its own: `ConnectionTuning.maxHealsPerIncident` is what bounds the
/// walk. A demoted rung is sticky for the process's lifetime: there is no
/// promotion probe, so the rung climbs back to a cheaper one only when the
/// process restarts.
class TransportLadder {
  TransportLadder({
    required this._daemonCapabilities,
    required this._forcedRung,
  });

  /// The installed helper's capability tokens, read lazily so a test seam or a
  /// later adapter swap is observed at the point of use.
  final Set<String> Function() _daemonCapabilities;

  /// The e2e force seam (see `ConnectionController.debugForceRung`), read
  /// lazily for the same reason.
  final TransportRung? Function() _forcedRung;

  /// The rung this process is on. Demotions stay sticky across connects to
  /// avoid re-paying for a failed path, and there is no promotion probe: the
  /// rung resets to the node's floor when the process restarts. A server move
  /// also moves the rung to the new node's floor, or to the highest rung that
  /// node advertises.
  TransportRung rung = TransportRung.native;

  /// The obfuscation parameters to build a conf for [dial] with, or null when
  /// this start's tunnel is stock WireGuard.
  ///
  /// Only the obfuscated rung carries them, because it is the only one pointed at
  /// the node's obfuscated device — and only that entry has a `params` field at
  /// all. The other two are stock: the native rung by definition, and the stream
  /// rung because the node's bridge injects into its *stock* device whatever else
  /// that node serves, so a stream session carries stock datagrams inside its TLS
  /// session.
  ObfuscationParams? obfuscationParamsFor(DialParams dial) =>
      transportFor(dial).params;

  /// The advertised entry for the rung this start is on.
  ///
  /// The one place a rung's advertisement is read, so the port, the parameters
  /// and the credential used to build a start can never come from a rung other
  /// than the one being started. Non-null by construction: [apply] has
  /// already refused a rung this node does not advertise or this build cannot
  /// assemble, and nothing between it and here changes the rung.
  TransportOption transportFor(DialParams dial) => dial.transportFor(rung)!;

  /// The node's own port for the rung this start is on.
  ///
  /// The rung's advertised port, which is that rung's own device: the node runs a
  /// separate device per transport, so a stock device cannot read obfuscation
  /// directives and an obfuscated device cannot read a stock handshake, and
  /// neither port is interchangeable with the other in either direction.
  int tunnelPortFor(DialParams dial) => transportFor(dial).port;

  /// The overlay address this start must claim.
  ///
  /// The node has one network per device, so the address follows the rung rather
  /// than the server: the obfuscated device routes only the addresses its own
  /// overlay contains, and a stock address sent there handshakes fine and then
  /// blackholes every packet — which reads as a blocked network and demotes the
  /// rung that was working.
  ///
  /// Only the obfuscated rung has a second address, and it is exactly the case
  /// [awgRungRunnable] gates on, so there is nothing to fall back to here. The
  /// stream rung is stock because the node's bridge injects into its *stock*
  /// device: a stream session carries stock WireGuard datagrams whatever else
  /// that node serves, and handing those to the obfuscated device is a handshake
  /// into a void.
  String overlayAddressFor(DialParams dial) =>
      rung == TransportRung.awg ? dial.awgAssignedIp! : dial.assignedIp;

  /// The in-tunnel resolver for this start.
  ///
  /// Same rule as the address: the node runs one systemd-resolved stub per
  /// interface, so the resolver has to be the one on the device this start's
  /// traffic reaches. Pushing the stock stub's address onto the obfuscated rung
  /// would send every DNS query to a device with no route for it.
  String overlayDnsFor(DialParams dial) =>
      rung == TransportRung.awg ? dial.awgDns! : dial.wgDns;

  /// Whether the obfuscated rung is something this start could actually build.
  ///
  /// The advertised entry carries the port and the parameter set; what it cannot
  /// carry is the *peer's* address on the obfuscated overlay, because that belongs
  /// to the device and is the same for every session. A rung without one is a
  /// conf whose every packet the node's second device cannot route — a tunnel
  /// that handshakes and then goes nowhere, which reads to the health ladder as a
  /// blocked network and demotes the rung that was working. So the rung counts as
  /// not offered rather than offered and broken, which is what the control
  /// plane's withholding on its own side is for.
  /// Both fields, because the pair is emitted together or not at all (see the
  /// backend factory) — checking one and then asserting the other would be a
  /// check of an invariant, not of input.
  bool awgRungRunnable(DialParams dial) =>
      dial.transportFor(TransportRung.awg) != null &&
      (dial.awgAssignedIp?.isNotEmpty ?? false) &&
      (dial.awgDns?.isNotEmpty ?? false);

  /// The stream transport for this start, or null unless this process is on the
  /// stream rung.
  ///
  /// Total by construction now: [rungRunnableHere] is what admits the stream
  /// rung onto the ladder, and it requires both a usable credential from the
  /// advertised entry and a data plane that can run it. So there is nothing left
  /// to check here — every value below is the one that gate accepted, and the
  /// rung below can neither be silently substituted nor invented.
  Future<TunnelTransport?> streamTransportFor(DialParams dial) async {
    if (rung != TransportRung.stream) return null;
    final credential = transportFor(dial).credential!;
    final ports = await allocateLoopbackPorts();
    return TunnelTransport(
      listen: '${TunnelTransport.loopbackHost}:${ports.listen}',
      deliver: '${TunnelTransport.loopbackHost}:${ports.deliver}',
      credential: credential,
    );
  }

  /// Moves the process one rung down when [dial]'s node advertises one below.
  /// Idempotent: a process already on the last advertised rung reports false, so
  /// the heal that demotes is also the only one that can.
  ///
  /// The walk is one rung per heal and never skips: with the advertised list
  /// there is no cheaper rung *unless the node says it runs one*, and the rung
  /// below is by definition the one the rung above has not disproved yet. How
  /// many steps an incident gets is [ConnectionTuning.maxHealsPerIncident]'s
  /// business, not this method's — a node serving two rungs below the floor is
  /// walked to the bottom of its own list, and one rung below gets exactly one
  /// step.
  ///
  /// [why] is the health reason that triggered the heal, so the log names the
  /// evidence the demotion acted on.
  bool demoteRung(DialParams dial, String why) {
    final next = nextRungFor(dial);
    if (next == null) return false;
    AppLog.info('transport demoted ($why) ${rung.name} -> ${next.name}');
    rung = next;
    return true;
  }

  /// The rung one step below the current one that [dial]'s node actually
  /// advertises, or null when there is nothing below to walk onto.
  ///
  /// The next entry in the advertised list, not the next value in the cost order:
  /// a node that serves only stock and stream must demote straight to stream, and
  /// one whose awg entry this platform cannot run must skip it. Reading the list
  /// is what makes both work without a per-server special case.
  ///
  /// Split out of [demoteRung] so the health tick can ask whether a heal
  /// would lower the rung *before* spending one, without mutating it: the
  /// ladder is only worth a restart when there is a rung underneath it.
  TransportRung? nextRungFor(DialParams dial) {
    final rungs = runnableRungs(dial);
    final at = rungs.indexOf(rung);
    if (at < 0 || at + 1 >= rungs.length) return null;
    return rungs[at + 1];
  }

  /// Whether a heal against [dial] would leave the rung lower. Pure: it reads
  /// the ladder without moving it, so a caller can gate on it and leave the
  /// ladder alone when the answer is no.
  bool hasLowerRung(DialParams dial) => nextRungFor(dial) != null;

  /// The rungs [dial]'s node advertises that this platform can actually start,
  /// cheapest first.
  ///
  /// The advertised list, minus what this build cannot start. Ordered by the
  /// *node*, so a walk down it is a walk down what that node really offers rather
  /// than down a fixed cost order the node may not serve — the two diverge the
  /// moment a node runs two devices and omits one, which is the case that used to
  /// be unrepresentable on the wire.
  List<TransportRung> runnableRungs(DialParams dial) => [
    for (final rung in dial.advertisedRungs)
      if (rungRunnableHere(dial, rung)) rung,
  ];

  /// Whether this build can start [rung] against [dial], given the node
  /// advertises it.
  ///
  /// A rung this build cannot start is not on the ladder, so it is never
  /// selected, never stepped onto, and never probed. This is the whole platform
  /// gate, and scoping it to *this dial* rather than to the rung alone is what
  /// lets the floor be a lookup: the answer differs per server (whether the node
  /// serves it) and per platform (whether it can be run), and both have to hold.
  bool rungRunnableHere(DialParams dial, TransportRung rung) => switch (rung) {
    TransportRung.native => true,
    TransportRung.awg => awgDataPlaneSupported() && awgRungRunnable(dial),
    // Two halves: the platform needs a bridge to run at all, and the installed
    // helper has to be one whose `up` would honour the spec. The credential's own
    // usability is already settled by `TransportOption.isComplete`.
    TransportRung.stream =>
      streamTransportSupported() &&
          _daemonCapabilities().contains(capStreamTransport),
  };

  /// The rung to start [dial] on, given the process's current one.
  ///
  /// The rule, stated exactly:
  ///
  /// > floor = the cheapest rung **the node advertises** that **this platform can
  /// > run**
  ///
  /// Not "the cheapest rung this platform can run" — that was the old derivation's
  /// blind spot, and with every node serving both formats it floors Apple to `awg`
  /// and makes the product unusable there. Scoped to the advertised list, a
  /// dual-format node floors every platform to `native`, because `native` is in the
  /// list and every platform can run it.
  ///
  /// On top of the floor, two bounds, both about the serving node rather than the
  /// network:
  ///
  ///  * Never start below it. A node serving only `awg` and `stream` floors here to
  ///    `stream`, which is the right answer rather than a refusal.
  ///  * Never keep a rung the node does not advertise. A server move can land on a
  ///    node with no stream credential, where a sticky stream rung could only throw
  ///    (see [streamTransportFor]).
  ///
  /// The health policy's demotion survives both: this only raises to the floor and
  /// lowers to the ceiling, so a walk down the ladder is never undone. A move onto a
  /// node that *does* advertise the sticky rung leaves it alone, so a roam is not
  /// charged for the walk again.
  ///
  /// Null means the node advertises no rung this build can start — a payload with no
  /// usable entry at all, not a format this build lacks. [apply] refuses rather
  /// than inventing a start the node could not read.
  TransportRung? rungFor(DialParams dial) {
    final runnable = runnableRungs(dial);
    if (runnable.isEmpty) return null;
    // Test seam (see `ConnectionController.debugForceRung`): an e2e walks the
    // whole ladder by pinning each rung, which the health policy would otherwise
    // only reach on a blocked network. Still scoped to `runnable`, so it can only
    // start a rung this node serves and this build can assemble.
    final forced = _forcedRung();
    if (forced != null && runnable.contains(forced)) return forced;
    if (runnable.contains(rung)) return rung;
    final ceiling = runnable.last;
    final floor = runnable.first;
    if (rung.index < floor.index) return floor;
    // Above the ceiling, or *between* two advertised rungs but served by neither
    // — the case an index range would read as "still inside the ladder" and start
    // on a rung the node does not serve. The ceiling is the right side of it:
    // reaching the unserved rung in the first place means the walk demoted past
    // the rungs below it, and those are the ones the network is blocking.
    return ceiling;
  }

  /// Applies [rungFor] before a start, logging the move, and refuses a server
  /// advertising no rung this build can produce a start for.
  ///
  /// Called at the top of every `_startWith` — the one point a connect, a
  /// switch, a heal and a cold restore all pass through — so a move onto a server
  /// with a different rung list can never start on the previous server's rung, and
  /// can never start on a rung the new node does not serve.
  ///
  /// Refusing is the point, and now it means one narrow thing: there is no entry
  /// here to build a conf from, so any start would be a guess. It is no longer the
  /// path a platform without an obfuscated data plane takes on an obfuscated
  /// region, because such a region advertises `native` and is started on it.
  void apply(DialParams dial) {
    final next = rungFor(dial);
    if (next == null) {
      throw UnsupportedError(
        'The server "${dial.serverName}" offers no transport this app build '
        'can use. Choose another server.',
      );
    }
    if (next == rung) return;
    AppLog.info(
      'transport rung set ${rung.name} -> ${next.name} '
      'server=${dial.serverName}',
    );
    rung = next;
  }
}
