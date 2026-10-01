part of 'connection_controller.dart';

/// The transport rungs, in the order they are tried.
///
/// Native is always first and costs an unobstructed network nothing. AmneziaWG
/// is the middle rung: obfuscated datagrams, no extra moving parts. Stream is
/// the last: the tunnel rides a TLS session to the node, which is what defeats
/// a network that blocks or fingerprints WireGuard's own UDP, and costs the
/// most when it fails.
///
/// The order is also the order [_demoteRung] walks. One rung at a time — a
/// stream transport already carries the tunnel inside a camouflaged session, so
/// the obfuscation parameters on top of it would be redundant, and the helper
/// rejects the combination.
enum ObfuscationRung {
  /// The kernel WireGuard data plane, pointed straight at the node.
  native,

  /// The in-process AmneziaWG device.
  awg,

  /// The tunnel's datagrams carried inside a TLS session to the node.
  stream,
}

/// The obfuscation ladder: native WireGuard first, AmneziaWG next, and the
/// stream transport last, each after a confirmed local stall (see
/// [_demoteRung]).
///
/// The demotion rides the existing heal rung — [_autoHeal] already restarts the
/// cached config offline, which is exactly the moment a fingerprint-blocked path
/// should be retried on a lower rung — so the ladder adds no budget, timer, or
/// state of its own. A heal that the next rung does not fix falls through to
/// the *existing* escalation (failover, then [_surfaceRecoveryExhausted])
/// rather than a new failure mode.
extension ConnectionObfuscation on ConnectionController {
  /// The rung this process is on. Sticky for the process lifetime: there is no
  /// automatic promotion back to native, because every promotion would re-pay
  /// for a probe that already failed, and a network that blocked the fast path
  /// once will do it again on the next connect.
  ObfuscationRung get obfuscationRung => _obfuscationRung;

  /// The obfuscation parameters to build a conf for [dial] with, or null unless
  /// this process is on the AWG rung.
  ///
  /// The rung itself already encodes every gate — [_demoteRung] only promotes
  /// onto it when the region offers AWG parameters and this platform has a data
  /// plane that runs them — so this only reads the state back.
  ObfuscationParams? _obfuscationParamsFor(DialParams dial) {
    if (_obfuscationRung != ObfuscationRung.awg) return null;
    return dial.obfuscation?.params;
  }

  /// The stream transport for this start, or null unless this process is on the
  /// stream rung.
  ///
  /// Returns null when the region offers no credential, and throws when the rung
  /// is selected but the platform or daemon cannot run it: those are different
  /// problems, and silently falling back to the native rung would defeat the
  /// heal that put us here by retrying the path just proven dead.
  Future<TunnelTransport?> _streamTransportFor(DialParams dial) async {
    if (_obfuscationRung != ObfuscationRung.stream) return null;
    final credential = dial.stream;
    if (credential == null || !credential.isUsable) {
      throw StateError('Stream rung selected without a usable credential.');
    }
    if (!streamTransportSupported()) {
      throw UnsupportedError(
        'Stream transport is not available on this platform.',
      );
    }
    if (!_daemonCapabilities.contains(capStreamTransport)) {
      throw UnsupportedError(
        'The installed helper cannot run a stream transport.',
      );
    }
    final ports = await allocateLoopbackPorts();
    return TunnelTransport(
      listen: '${TunnelTransport.loopbackHost}:${ports.listen}',
      deliver: '${TunnelTransport.loopbackHost}:${ports.deliver}',
      credential: credential,
    );
  }

  /// Moves the process one rung down when [dial]'s region can serve the next
  /// one. Idempotent: a process already on the last usable rung reports false,
  /// so the heal that demotes is also the only one that can.
  ///
  /// The walk is a single step, not a jump: a heal that moves native directly
  /// to stream would skip the cheaper rung and, if the stream failed, leave no
  /// evidence about whether AWG would have worked.
  ///
  /// [why] is the health reason that triggered the heal, so the log names the
  /// evidence the demotion acted on.
  bool _demoteRung(DialParams dial, String why) {
    final next = switch (_obfuscationRung) {
      ObfuscationRung.native => _firstAvailableRung(dial),
      ObfuscationRung.awg =>
        _streamRungAvailable(dial) ? ObfuscationRung.stream : null,
      // Nothing below stream: a heal here escalates through the existing
      // failover instead of retrying a rung that does not exist.
      ObfuscationRung.stream => null,
    };
    if (next == null) return false;
    AppLog.info(
      'transport demoted ($why) ${_obfuscationRung.name} -> ${next.name}',
    );
    _obfuscationRung = next;
    return true;
  }

  /// The first rung below native that [dial]'s region and this platform can
  /// actually run, preferring AWG because it is the cheaper one.
  ObfuscationRung? _firstAvailableRung(DialParams dial) {
    if (_awgRungAvailable(dial)) return ObfuscationRung.awg;
    if (_streamRungAvailable(dial)) return ObfuscationRung.stream;
    return null;
  }

  bool _awgRungAvailable(DialParams dial) {
    final obf = dial.obfuscation;
    return obf != null && obf.isAwg && awgDataPlaneSupported();
  }

  /// Whether the stream rung could run here at all: the region must offer a
  /// usable credential, this platform must have a data plane for it, and the
  /// installed daemon must advertise the capability. All three, because
  /// selecting the rung without any of them can only fail.
  bool _streamRungAvailable(DialParams dial) {
    final credential = dial.stream;
    return credential != null &&
        credential.isUsable &&
        streamTransportSupported() &&
        _daemonCapabilities.contains(capStreamTransport);
  }
}
