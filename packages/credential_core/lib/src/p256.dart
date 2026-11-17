import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bytes.dart';

/// ECDSA over NIST P-256 with SHA-256. Public keys are compressed SEC1 (33 bytes); signatures are
/// raw `r || s` (64 bytes). See docs/credential-spec.md section 3.2.

final ECDomainParameters _p256 = ECCurve_secp256r1();
final BigInt _n = _p256.n;

BigInt _bigFrom(Uint8List b, [int start = 0, int? end]) {
  var r = BigInt.zero;
  for (var i = start; i < (end ?? b.length); i++) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _bytes32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

Uint8List _sha256(Uint8List message) => SHA256Digest().process(message);

/// Verifies a raw 64-byte signature. Accepts both low-S and high-S, because Android Keystore does
/// not normalise S. Never throws; any malformed input is simply "not valid".
bool verifyEcdsa(Uint8List publicKey, Uint8List message, Uint8List signature) {
  try {
    if (publicKey.length != 33 || signature.length != 64) return false;
    final q = _p256.curve.decodePoint(publicKey);
    if (q == null) return false;
    final r = _bigFrom(signature, 0, 32);
    final s = _bigFrom(signature, 32, 64);
    if (r < BigInt.one || r >= _n || s < BigInt.one || s >= _n) return false;
    final signer = ECDSASigner(null)..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, _p256)));
    return signer.verifySignature(_sha256(message), ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

/// Deterministic (RFC 6979) software signer for tests and tools. The phone signs with the
/// Android Keystore instead (see [DeviceSigner]).
Uint8List signEcdsa(Uint8List privateKey, Uint8List message) {
  final signer = ECDSASigner(null, HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_bigFrom(privateKey), _p256)));
  final sig = signer.generateSignature(_sha256(message)) as ECSignature;
  return concatBytes([_bytes32(sig.r), _bytes32(sig.s)]);
}

/// Compressed public key for a private key. Tests and tools only.
Uint8List publicKeyOf(Uint8List privateKey) {
  final q = _p256.G * _bigFrom(privateKey);
  return q!.getEncoded(true);
}

/// Compresses an uncompressed SEC1 point (`04 || X || Y`, 65 bytes).
Uint8List compressPublicKey(Uint8List uncompressed) {
  if (uncompressed.length != 65 || uncompressed[0] != 0x04) {
    throw ArgumentError('expected a 65-byte uncompressed P-256 point');
  }
  final yIsOdd = uncompressed[64].isOdd;
  return Uint8List.fromList([yIsOdd ? 0x03 : 0x02, ...uncompressed.sublist(1, 33)]);
}

/// Android Keystore's `PublicKey.getEncoded()` is an X.509 SubjectPublicKeyInfo. For P-256 it is
/// 91 bytes and ends with the uncompressed point.
Uint8List compressedPublicKeyFromSpki(Uint8List spki) {
  if (spki.length != 91) throw ArgumentError('expected a 91-byte P-256 SubjectPublicKeyInfo');
  return compressPublicKey(spki.sublist(spki.length - 65));
}

/// Converts a DER `SEQUENCE { INTEGER r, INTEGER s }` (what Android Keystore and cloud KMS return)
/// to the raw 64-byte `r || s` used on the wire. Throws [FormatException] on anything else.
Uint8List ecdsaDerToRaw(Uint8List der) {
  var pos = 0;
  int readByte() {
    if (pos >= der.length) throw const FormatException('truncated DER signature');
    return der[pos++];
  }

  int readLength() {
    final first = readByte();
    if (first < 0x80) return first;
    if (first == 0x81) return readByte();
    throw const FormatException('unsupported DER length');
  }

  Uint8List readInteger() {
    if (readByte() != 0x02) throw const FormatException('expected DER INTEGER');
    final len = readLength();
    if (len == 0 || pos + len > der.length) throw const FormatException('bad DER INTEGER length');
    var value = der.sublist(pos, pos + len);
    pos += len;
    if (value[0] & 0x80 != 0) throw const FormatException('negative DER INTEGER');
    while (value.length > 1 && value[0] == 0) {
      value = value.sublist(1);
    }
    if (value.length > 32) throw const FormatException('DER INTEGER too large');
    return Uint8List(32)..setRange(32 - value.length, 32, value);
  }

  if (readByte() != 0x30) throw const FormatException('expected DER SEQUENCE');
  final seqLen = readLength();
  if (pos + seqLen != der.length) throw const FormatException('bad DER SEQUENCE length');
  final r = readInteger();
  final s = readInteger();
  if (pos != der.length) throw const FormatException('trailing bytes after DER signature');
  return concatBytes([r, s]);
}
