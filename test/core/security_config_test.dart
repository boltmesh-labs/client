import 'dart:convert';
import 'dart:io';

import 'package:boltmesh/core/dio_client.dart';
import 'package:boltmesh/core/storage_options.dart';
import 'package:boltmesh/features/vpn/data/platform_info.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Self-signed test certificate (CN=pintest.example), openssl-generated.
const _certDerB64 =
    'MIIDFTCCAf2gAwIBAgIUBbnbYaEz5fl2VEBCWZHcK/I/X0AwDQYJKoZIhvcNAQEL'
    'BQAwGjEYMBYGA1UEAwwPcGludGVzdC5leGFtcGxlMB4XDTI2MDkyMTIwMjM0NVoX'
    'DTM2MDkxODIwMjM0NVowGjEYMBYGA1UEAwwPcGludGVzdC5leGFtcGxlMIIBIjAN'
    'BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApCkV9pJ1s+31n5a6eQt9X1TnC2A8'
    'LLhaDu2yYIf22fyZFZOPbH9VaQj80D1UamQGGvrHJYmtE5lwlsg8eE0/X0JTGcoF'
    'ILrWuvkcyAcC8S1AIW7ECKCIOD6ItY8mmeTglSITGBrJtouFcdVW5AIqAxbnCWez'
    'W2ztIkSrZ0M7WWHokGLWzLlImRVtxI9zQbKxsFgjr1cGYWCupxaEmPvNAAMdO7mL'
    'brYxsH47ENd502ZELM9LMv+KNgi4B/c04EFSYLBb5URpnjThpLQfTF8EB0CuUuri'
    '+7czBgwZ0RbGzHkhkIMhy1JBxDvmglOQmg2Hw8zEBbXj2wxmLvpu/r4mUwIDAQAB'
    'o1MwUTAdBgNVHQ4EFgQUC4v+JG9P6wnmYX1NhNJ4zogYkF4wHwYDVR0jBBgwFoAU'
    'C4v+JG9P6wnmYX1NhNJ4zogYkF4wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B'
    'AQsFAAOCAQEAoiOWximOyISvg/0jlTovayP8K2Tb8a17y29OFhZpaWr6GYANs4SO'
    'imXg1WxZO9dghzVIbrYc+d6NDmalUcn58dPYv2VUB7Vd3ReHLDs3tivUmRj7puqi'
    'huhd0KKwakcbdkf+C8+4pXI9F5nHffjn7S0khsP9PRiEypAhcGrW35P0wFeluAFN'
    'ok/FZBVsmGARSm89yVmvEmABTF41sM0CBmrrskMMyKqgMckmVdYK8Vml1cCwPN0A5'
    'efGnm1dzU/sBYlmeRR2oJkB231iE13yQBG/I7oYVUakOSxqcoI9Q+EjijXPh9iv2'
    'iy8VtRHN2G+VCa/rnm6vPLz7HrjRD75MQ==';

class FakeCert implements X509Certificate {
  FakeCert(this.derBytes);
  final Uint8List derBytes;

  @override
  Uint8List get der => derBytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('shared secure storage', () {
    test('apple secrets are device-only, first-unlock', () {
      expect(
        kSharedSecureStorage.iOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
      expect(kSharedSecureStorage.iOptions.synchronizable, isFalse);
      expect(
        kSharedSecureStorage.mOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
      expect(kSharedSecureStorage.mOptions.synchronizable, isFalse);
    });

    test('android never silently wipes on keystore errors', () {
      expect(kSharedSecureStorage.aOptions.toMap()['resetOnError'], 'false');
    });
  });

  group('isInsecureReleaseBuild', () {
    test('flags http only in release mode', () {
      expect(
        isInsecureReleaseBuild('http://localhost:8000/v1', releaseMode: true),
        isTrue,
      );
      expect(
        isInsecureReleaseBuild('https://api.example.com/v1', releaseMode: true),
        isFalse,
      );
      expect(isInsecureReleaseBuild('http://localhost:8000/v1'), isFalse);
      // Under `flutter test` releaseMode defaults to false (kReleaseMode).
      expect(isInsecureReleaseBuild('http://localhost:8000/v1'), isFalse);
    });
  });

  group('configureTlsPinning', () {
    // Self-signed cert (CN=pintest.example), generated with openssl; the pin
    // is SHA-256 over its SubjectPublicKeyInfo.
    final certDer = base64Decode(_certDerB64);
    const pin = 'M5ZGVNDsXOrSCEKBoqjxr+i1Qundr4EZb5cTfGTD8eE=';

    test('no pins leaves platform trust untouched', () {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      configureTlsPinning(dio, pins: const []);
      final dynamic validate =
          (dio.httpClientAdapter as dynamic).validateCertificate;
      expect(validate, isNull);
    });

    test('matching SPKI passes, others fail', () {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      configureTlsPinning(dio, pins: const [pin]);
      final dynamic validate =
          (dio.httpClientAdapter as dynamic).validateCertificate;
      expect(validate, isNotNull);
      expect(validate(FakeCert(certDer), 'example.com', 443) as bool, isTrue);
      expect(
        validate(FakeCert(Uint8List.fromList([9, 9])), 'example.com', 443)
            as bool,
        isFalse,
      );
      expect(validate(null, 'example.com', 443) as bool, isFalse);
    });

    test('pinnedDio rejects cleartext base URLs in release mode', () {
      expect(
        () => pinnedDio(
          BaseOptions(baseUrl: 'http://localhost:8000/health'),
          releaseMode: true,
        ),
        throwsStateError,
      );
    });
  });

  group('resolveProviderBundleId', () {
    test('non-apple platforms pass empty string', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(resolveProviderBundleId(platform: p, bundleId: 'com.x.ext'), '');
      }
    });

    test('apple platforms require the dart-define', () {
      expect(
        () => resolveProviderBundleId(platform: TargetPlatform.iOS),
        throwsStateError,
      );
      expect(
        resolveProviderBundleId(
          platform: TargetPlatform.iOS,
          bundleId: 'com.boltmesh.app.WGExtension',
        ),
        'com.boltmesh.app.WGExtension',
      );
      expect(
        resolveProviderBundleId(
          platform: TargetPlatform.macOS,
          bundleId: 'com.boltmesh.app.WGExtension',
        ),
        'com.boltmesh.app.WGExtension',
      );
    });

    test('web always passes empty string', () {
      expect(
        resolveProviderBundleId(
          platform: TargetPlatform.iOS,
          bundleId: 'com.x.ext',
          web: true,
        ),
        '',
      );
    });
  });
}
