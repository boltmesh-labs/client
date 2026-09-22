/// Minimal X.509 DER walker that extracts the `SubjectPublicKeyInfo`.
///
/// Public-key (SPKI) pinning is preferred over leaf-certificate pinning: the
/// leaf DER changes on every renewal, while the key (and therefore its SPKI)
/// usually survives re-issuance, so a pin does not break the app the day the
/// backend rotates a certificate. Dart's `X509Certificate` exposes only the
/// whole certificate, so the SPKI has to be walked out of the DER here.
///
/// Layout (RFC 5280):
/// `Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
/// signatureValue }` and `TBSCertificate ::= SEQUENCE { version [0] OPTIONAL,
/// serialNumber, signature, issuer, validity, subject,
/// subjectPublicKeyInfo, ... }`.
library;

/// Returns the full DER encoding of the `SubjectPublicKeyInfo` (the SEQUENCE,
/// header included) from [certificateDer].
///
/// Throws [FormatException] when the input is not a parseable X.509
/// certificate. Callers must treat a throw as "pin mismatch" (fail closed).
List<int> subjectPublicKeyInfoDer(List<int> certificateDer) {
  final cert = _Tlv.read(certificateDer, 0);
  if (cert.tag != 0x30) {
    throw const FormatException('Not an X.509 certificate.');
  }
  final tbs = _Tlv.read(certificateDer, cert.contentStart);
  if (tbs.tag != 0x30) {
    throw const FormatException('Certificate has no TBSCertificate.');
  }
  var offset = tbs.contentStart;
  if (_Tlv.peekTag(certificateDer, offset) == 0xa0) {
    offset = _Tlv.read(certificateDer, offset).end; // version [0] EXPLICIT
  }
  // serialNumber, signature, issuer, validity, subject.
  for (var i = 0; i < 5; i++) {
    offset = _Tlv.read(certificateDer, offset).end;
  }
  final spki = _Tlv.read(certificateDer, offset);
  if (spki.tag != 0x30) {
    throw const FormatException('Certificate has no SubjectPublicKeyInfo.');
  }
  return certificateDer.sublist(spki.start, spki.end);
}

/// One DER tag-length-value. [start] is the tag byte, [contentStart] the first
/// content byte, [end] the first byte after the value.
class _Tlv {
  const _Tlv(this.tag, this.start, this.contentStart, this.end);

  final int tag;
  final int start;
  final int contentStart;
  final int end;

  static int peekTag(List<int> bytes, int offset) {
    if (offset >= bytes.length) {
      throw const FormatException('Truncated DER.');
    }
    return bytes[offset];
  }

  static _Tlv read(List<int> bytes, int offset) {
    final start = offset;
    if (offset + 2 > bytes.length) {
      throw const FormatException('Truncated DER.');
    }
    final tag = bytes[offset++];
    var length = bytes[offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || offset + count > bytes.length) {
        throw const FormatException('Invalid DER length.');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[offset++];
      }
    }
    final contentStart = offset;
    final end = contentStart + length;
    if (end > bytes.length) {
      throw const FormatException('Truncated DER value.');
    }
    return _Tlv(tag, start, contentStart, end);
  }
}
