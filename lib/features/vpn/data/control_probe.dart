import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dio_client.dart';
import '../../../core/env.dart';
import '../../../core/log.dart';

/// Layer 3: cheap out-of-band control-plane probe.
///
/// A bare unauthenticated `GET <apiBaseUrl>/health` on its own short-
/// timeout Dio — never the session client, so it can't burn the
/// session-budgeted `status_limiter` or trigger the 401 refresh hook.
/// Any HTTP response (even 5xx) proves the control plane is reachable;
/// only transport failures mean unreachable. Null means unknown — the
/// probe errored, or the API is on loopback and the probe is skipped: a
/// local/SSH-forwarded control plane shares the host underlay a full
/// tunnel routes away, so probing it would only report the expected
/// stranding. Callers stay fail-open on null.
class ControlPlaneProbe {
  /// One Dio per distinct timeout, kept for the lifetime of this
  /// (provider-singleton) probe: a fresh Dio per health tick would allocate
  /// and drop an `HttpClient` every 15s. Both production callers use
  /// [ConnectionTuning.controlProbeTimeout], so this holds a single entry.
  final Map<Duration, Dio> _clients = {};

  /// Tests inject a client factory (and the base URL / loopback decision)
  /// instead: the production values are compile-time `Env` constants, and
  /// `flutter test` stubs `HttpClient` so a real socket is never reachable.
  /// The seam still exercises the real [Dio] request path and, crucially, the
  /// tri-state branching below.
  final String? apiBaseUrl;
  final bool? loopbackApi;
  final Dio Function(String healthEndpoint, Duration timeout)? dioFactory;

  ControlPlaneProbe({this.apiBaseUrl, this.loopbackApi, this.dioFactory});

  Dio _clientFor(String healthEndpoint, Duration timeout) =>
      _clients.putIfAbsent(
        timeout,
        () =>
            dioFactory?.call(healthEndpoint, timeout) ??
            pinnedDio(
              BaseOptions(
                baseUrl: healthEndpoint,
                connectTimeout: timeout,
                receiveTimeout: timeout,
                sendTimeout: timeout,
              ),
            ),
      );

  Future<bool?> check({Duration timeout = const Duration(seconds: 5)}) async {
    if (loopbackApi ?? Env.isLoopbackApi) return null;
    try {
      final healthEndpoint = healthUrl(apiBaseUrl ?? Env.apiBaseUrl);
      final response = await _clientFor(
        healthEndpoint,
        timeout,
      ).get<dynamic>('');
      AppLog.info('control probe ok status=${response.statusCode}');
      return true;
    } on DioException catch (e) {
      // App-level rejections still prove reachability; only a missing
      // response means the path is dead.
      if (e.response != null) {
        AppLog.info('control probe ok status=${e.response?.statusCode}');
        return true;
      }
      AppLog.error('control probe unreachable', e);
      return false;
    } catch (e) {
      AppLog.error('control probe failed', e);
      return null;
    }
  }

  /// `<apiBaseUrl>` without a trailing `/v1` plus `/health`. Pure so it
  /// can be unit-tested (`/health` is served at the app root, not `/v1`).
  static String healthUrl(String apiBaseUrl) {
    var v = stripTrailingSlashes(apiBaseUrl);
    if (v.toLowerCase().endsWith('/v1')) {
      v = v.substring(0, v.length - 3);
    }
    return '$v/health';
  }
}

final controlPlaneProbeProvider = Provider<ControlPlaneProbe>(
  (_) => ControlPlaneProbe(),
);
