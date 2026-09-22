import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'x509_spki.dart';

/// Installs SPKI pin validation on [dio]'s native adapter.
///
/// Returns false when the adapter does not expose `validateCertificate`
/// (e.g. a custom adapter in tests), leaving the caller to decide whether
/// that is a hard failure. Type-checked against `IOHttpClientAdapter`, so
/// there is no unchecked `dynamic` write.
bool installSpkiPinning(Dio dio, List<String> pins) {
  final adapter = dio.httpClientAdapter;
  if (adapter is! IOHttpClientAdapter) return false;
  adapter.validateCertificate = (certificate, host, port) {
    if (certificate == null) return false;
    final String encoded;
    try {
      encoded = base64Encode(
        sha256.convert(subjectPublicKeyInfoDer(certificate.der)).bytes,
      );
    } catch (_) {
      // Unparseable certificate: reject rather than silently trust it.
      return false;
    }
    return pins.contains(encoded);
  };
  return true;
}
