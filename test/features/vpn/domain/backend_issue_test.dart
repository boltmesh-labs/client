import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no error classifies to no issue', () {
    expect(classifyBackendIssue(null), isNull);
  });

  test('transport failures are unreachable, not auth', () {
    for (final kind in [ApiErrorKind.network, ApiErrorKind.tls]) {
      expect(
        classifyBackendIssue(ApiException(kind, 'x')),
        BackendIssue.unreachable,
      );
    }
  });

  test('401 is authExpired', () {
    expect(
      classifyBackendIssue(
        const ApiException(ApiErrorKind.unauthorized, 'x', 401),
      ),
      BackendIssue.authExpired,
    );
  });

  test('403 subscription and device-limit are subscriptionInactive', () {
    for (final kind in [
      ApiErrorKind.forbiddenNoSubscription,
      ApiErrorKind.deviceLimit,
    ]) {
      expect(
        classifyBackendIssue(ApiException(kind, 'x', 403)),
        BackendIssue.subscriptionInactive,
      );
    }
  });

  test('answered-but-unhealthy is serverError', () {
    for (final kind in [
      ApiErrorKind.unknown,
      ApiErrorKind.noCapacity,
      ApiErrorKind.rateLimited,
      ApiErrorKind.validation,
    ]) {
      expect(
        classifyBackendIssue(ApiException(kind, 'x')),
        BackendIssue.serverError,
      );
    }
  });

  test('recovery-owned errors raise no banner', () {
    for (final kind in [
      ApiErrorKind.notFound,
      ApiErrorKind.noActivePeer,
      ApiErrorKind.alreadyConnected,
      ApiErrorKind.keyInUse,
      ApiErrorKind.idempotencyConflict,
    ]) {
      expect(classifyBackendIssue(ApiException(kind, 'x')), isNull);
    }
  });
}
