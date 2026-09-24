import '../../../core/errors.dart';

/// Actionable cause behind a degraded connected session's control-plane
/// interaction, so the UI can tell "the server answered but rejected us"
/// (auth / subscription) apart from "we could not reach the server at all".
///
/// Pure (no Riverpod/timers/storage), like `diagnosis_policy.dart`, so the
/// classification is unit-testable in isolation and reusable by banners,
/// the diagnostics footer, and the controller.
enum BackendIssue {
  /// No response at all: connection refused/reset, timeout, DNS or TLS.
  /// The tunnel may still be up; the control plane is simply unreachable.
  unreachable,

  /// The backend answered 401: the access token is expired or revoked and
  /// the 401 interceptor's single refresh did not recover it. The auth
  /// listener signs the user out; this explains why before the login gate
  /// swaps in.
  authExpired,

  /// The backend answered 403 (no active subscription / device limit):
  /// reachable but not entitled. Distinct from a network failure.
  subscriptionInactive,

  /// The backend answered but is unhealthy: 5xx, 429, or an unclassified
  /// app-level rejection. Reachability itself is proven.
  serverError,
}

/// Maps a classified backend error to a user-actionable [BackendIssue], or
/// null when it is not a connected-session control-plane problem.
///
/// 404 device-gone and the 409 conflict family have dedicated recovery paths
/// (reprovision, fresh-key retry, config reload) and must not raise a
/// "backend is unhealthy" banner.
BackendIssue? classifyBackendIssue(ApiException? error) {
  final kind = error?.kind;
  if (kind == null) return null;
  switch (kind) {
    case ApiErrorKind.network:
    case ApiErrorKind.tls:
      return BackendIssue.unreachable;
    case ApiErrorKind.unauthorized:
      return BackendIssue.authExpired;
    case ApiErrorKind.forbiddenNoSubscription:
    case ApiErrorKind.deviceLimit:
      return BackendIssue.subscriptionInactive;
    case ApiErrorKind.forbidden:
    case ApiErrorKind.unknown:
    case ApiErrorKind.noCapacity:
    case ApiErrorKind.rateLimited:
    case ApiErrorKind.validation:
      return BackendIssue.serverError;
    case ApiErrorKind.notFound:
    case ApiErrorKind.noActivePeer:
    case ApiErrorKind.alreadyConnected:
    case ApiErrorKind.keyInUse:
    case ApiErrorKind.idempotencyConflict:
      return null;
  }
}
