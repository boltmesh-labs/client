import 'dart:convert';

import 'package:boltmesh/core/x509_spki.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final certDer = base64Decode(_certDerB64);

  test('extracts the SubjectPublicKeyInfo from a certificate', () {
    expect(base64Encode(subjectPublicKeyInfoDer(certDer)), _spkiDerB64);
  });

  test('SPKI hash matches the openssl-computed pin', () {
    final hash = base64Encode(
      sha256.convert(subjectPublicKeyInfoDer(certDer)).bytes,
    );
    expect(hash, 'M5ZGVNDsXOrSCEKBoqjxr+i1Qundr4EZb5cTfGTD8eE=');
  });

  test('rejects input that is not a DER certificate', () {
    expect(
      () => subjectPublicKeyInfoDer(const [1, 2, 3, 4]),
      throwsFormatException,
    );
    expect(() => subjectPublicKeyInfoDer(const []), throwsFormatException);
  });
}

// Self-signed test certificate (CN=pintest.example), openssl-generated; the
// expected SPKI below was produced with
// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER`.
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

const _spkiDerB64 =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApCkV9pJ1s+31n5a6eQt9'
    'X1TnC2A8LLhaDu2yYIf22fyZFZOPbH9VaQj80D1UamQGGvrHJYmtE5lwlsg8eE0/'
    'X0JTGcoFILrWuvkcyAcC8S1AIW7ECKCIOD6ItY8mmeTglSITGBrJtouFcdVW5AIq'
    'AxbnCWezW2ztIkSrZ0M7WWHokGLWzLlImRVtxI9zQbKxsFgjr1cGYWCupxaEmPvN'
    'AAMdO7mLbrYxsH47ENd502ZELM9LMv+KNgi4B/c04EFSYLBb5URpnjThpLQfTF8E'
    'B0CuUuri+7czBgwZ0RbGzHkhkIMhy1JBxDvmglOQmg2Hw8zEBbXj2wxmLvpu/r4m'
    'UwIDAQAB';
