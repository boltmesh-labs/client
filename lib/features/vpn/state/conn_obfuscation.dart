part of 'connection_controller.dart';

/// The transport rungs, in the order they are tried.
///
/// Native is always first and costs an unobstructed network nothing. AmneziaWG
/// is the middle rung: obfuscated datagrams, no extra moving parts. Stream is
/// the last: the tunnel rides a TLS session to the node, which is what defeats
/// a network that blocks or fingerprints WireGuard's own UDP, and costs the
/// most when it fails.
///
/// The order is also the order [_demoteRung] walks. The rungs are alternatives
/// — one at a time, never stacked — but the *inner* WireGuard format follows
/// the region, not the rung: an obfuscated region's node runs the AmneziaWG
/// device, so the datagrams it receives must carry the obfuscation directives
/// whether they arrive directly (AWG) or inside a stream transport. The
/// stream's TLS session is the outer camouflage; the inner format still has to
/// match the node's device.
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

  /// The obfuscation parameters to build a conf for [dial] with, or null when
  /// this start's tunnel is stock WireGuard.
  ///
  /// The native rung is stock by definition — it is the probe that discovers
  /// whether a plain WireGuard path exists. Every rung below it follows the
  /// region: an obfuscated region's node runs the AmneziaWG device, so both the
  /// AWG rung and the stream rung build an obfuscated conf, and the stream's
  /// bridge then carries those obfuscated datagrams inside its TLS session. The
  /// format is the region's, not the rung's.
  ObfuscationParams? _obfuscationParamsFor(DialParams dial) {
    if (_obfuscationRung == ObfuscationRung.native) return null;
    final obf = dial.obfuscation;
    return obf != null && obf.isAwg ? obf.params : null;
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
  ///
  /// An obfuscated region adds a fourth: the stream's inner datagrams carry the
  /// region's obfuscation directives, so this platform must also be able to run
  /// the obfuscated data plane that produces them. On a stock region there is
  /// no such requirement.
  bool _streamRungAvailable(DialParams dial) {
    final credential = dial.stream;
    if (credential == null ||
        !credential.isUsable ||
        !streamTransportSupported() ||
        !_daemonCapabilities.contains(capStreamTransport)) {
      return false;
    }
    final obf = dial.obfuscation;
    if (obf != null && obf.isAwg && !awgDataPlaneSupported()) return false;
    return true;
  }
}
