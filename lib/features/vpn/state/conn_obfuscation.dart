part of 'connection_controller.dart';

/// Obfuscation ladder: native WireGuard first, AmneziaWG after a confirmed
/// local stall (see [_obfuscationDemoted]).
///
/// The demotion rides the existing heal rung — [_autoHeal] already restarts
/// the cached config offline, which is exactly the moment a fingerprint-
/// blocked path should be retried with obfuscation — so the ladder adds no
/// budget, timer, or state of its own. A heal that the obfuscated conf does
/// not fix falls through to the *existing* escalation (failover, then
/// [_surfaceRecoveryExhausted]) rather than a new failure mode.
extension ConnectionObfuscation on ConnectionController {
  /// The obfuscation parameters to build a conf for [dial] with, or null for
  /// the native data plane.
  ///
  /// Three conditions, all required: the region serves an obfuscation
  /// descriptor with a complete parameter set ([Obfuscation.isAwg], so a
  /// malformed descriptor can never produce a half-obfuscated tunnel), this
  /// platform has a data plane that can run it
  /// ([awgDataPlaneSupported]), and the process has been demoted.
  ObfuscationParams? _obfuscationParamsFor(DialParams dial) {
    if (!_obfuscationDemoted) return null;
    if (!awgDataPlaneSupported()) return null;
    final obf = dial.obfuscation;
    if (obf == null || !obf.isAwg) return null;
    return obf.params;
  }

  /// Moves the process onto the obfuscated rung when [dial]'s region offers
  /// it. Idempotent: a demoted process (or a region with no descriptor)
  /// reports false, so the heal that demotes is also the only one that can.
  ///
  /// [why] is the health reason that triggered the heal, so the log names
  /// the evidence the demotion acted on.
  bool _demoteToObfuscation(DialParams dial, String why) {
    if (_obfuscationDemoted) return false;
    if (!awgDataPlaneSupported()) return false;
    final obf = dial.obfuscation;
    if (obf == null || !obf.isAwg) return false;
    _obfuscationDemoted = true;
    AppLog.info('obfuscation demoted ($why) region offers AmneziaWG params');
    return true;
  }
}
