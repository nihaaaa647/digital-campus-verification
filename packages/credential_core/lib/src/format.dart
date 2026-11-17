// Digital Campus ID credential format v1. The normative description is docs/credential-spec.md and
// spec/test-vectors/v1.json is the executable contract. The TypeScript implementation in
// supabase/functions/_shared/credential.ts must agree with this file on every vector.

import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'cbor.dart';
import 'models.dart';
import 'p256.dart';

const int formatVersion = 1;
const int defaultMaxAgeS = 45;
const int defaultMaxFutureS = 10;
const int _maxQrChars = 1024;

Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));

/// Domain-separation prefixes, ASCII plus one NUL byte (spec section 3.3).
final Uint8List ctxCred = _ascii('DCID1-CRED\x00');
final Uint8List ctxScan = _ascii('DCID1-SCAN\x00');
final Uint8List ctxRevo = _ascii('DCID1-REVO\x00');

class _Failure implements Exception {
  const _Failure(this.failure);
  final ScanFailure failure;
}

Object? _tryDecode(Uint8List bytes) {
  try {
    return decodeCbor(bytes);
  } on CborException {
    return null;
  }
}

// ---------------------------------------------------------------- credential

/// Canonical encoding. Dart has no NFC normaliser, so [Credential.name] must already be NFC.
/// The phone never issues credentials; this exists for tests and tools.
Uint8List encodeCredential(Credential c) => cborMap({
      0: cborUint(c.v),
      1: cborUint(c.kv),
      2: cborUint(c.sid),
      3: cborText(c.roll),
      4: cborText(c.name),
      5: cborText(c.branch),
      6: cborUint(c.year),
      7: cborUint(c.pass),
      8: cborBytes(c.photo),
      9: cborBytes(c.dpk),
      10: cborUint(c.iat),
      11: cborUint(c.exp),
    });

Credential _parseCredential(Uint8List bytes) {
  final top = _tryDecode(bytes);
  if (top is! Map<int, Object>) throw const _Failure(ScanFailure.malformed);

  final version = top[0];
  if (version is! int) throw const _Failure(ScanFailure.malformed);
  if (version != formatVersion) throw const _Failure(ScanFailure.unsupportedVersion);

  int number(int key) {
    final x = top[key];
    if (x is! int) throw const _Failure(ScanFailure.malformed);
    return x;
  }

  String text(int key, int min, int max) {
    final x = top[key];
    if (x is! String) throw const _Failure(ScanFailure.malformed);
    final n = utf8.encode(x).length;
    if (n < min || n > max) throw const _Failure(ScanFailure.malformed);
    return x;
  }

  Uint8List bytesOf(int key, int length) {
    final x = top[key];
    if (x is! Uint8List || x.length != length) throw const _Failure(ScanFailure.malformed);
    return x;
  }

  final c = Credential(
    v: version,
    kv: number(1),
    sid: number(2),
    roll: text(3, 1, 16),
    name: text(4, 1, 64),
    branch: text(5, 1, 12),
    year: number(6),
    pass: number(7),
    photo: bytesOf(8, 16),
    dpk: bytesOf(9, 33),
    iat: number(10),
    exp: number(11),
  );
  final valid = c.sid >= 1 &&
      c.year >= 1 &&
      c.year <= 6 &&
      c.pass <= PassType.visitor.code &&
      (c.dpk[0] == 0x02 || c.dpk[0] == 0x03) &&
      c.exp > c.iat;
  if (!valid) throw const _Failure(ScanFailure.malformed);
  return c;
}

/// Decodes the credential the phone stored. The phone trusts it because the server signed it and the
/// app verified that signature on download; scanners use [verifyScan] instead.
/// Throws [FormatException] with the failure code if the bytes are not a valid v1 credential.
Credential decodeCredential(Uint8List bytes) {
  try {
    return _parseCredential(bytes);
  } on _Failure catch (f) {
    throw FormatException('credential rejected: ${f.failure.code}');
  }
}

/// The bytes the college key signs.
Uint8List collegeSigningInput(Uint8List credentialBytes) => concatBytes([ctxCred, credentialBytes]);

/// The bytes the device key signs on every QR refresh.
Uint8List deviceSigningInput(int ts, Uint8List credentialBytes) => concatBytes([ctxScan, u64be(ts), credentialBytes]);

// ---------------------------------------------------------------- signed credential (DK1.)

String encodeSignedCredential(Uint8List credentialBytes, Uint8List collegeSig) =>
    'DK1.${toBase64Url(cborArray([cborBytes(credentialBytes), cborBytes(collegeSig)]))}';

/// Parses the `DK1.` text the server returns. Returns null if it is not well formed. This does not
/// check the signature: the caller verifies it with [verifyEcdsa] and [collegeSigningInput].
SignedCredential? parseSignedCredential(String text) {
  if (!text.startsWith('DK1.')) return null;
  final body = fromBase64Url(text.substring(4));
  if (body == null) return null;
  final arr = _tryDecode(body);
  if (arr is! List<Object> || arr.length != 2) return null;
  final cred = arr[0];
  final sig = arr[1];
  if (cred is! Uint8List || sig is! Uint8List || sig.length != 64) return null;
  return SignedCredential(cred, sig);
}

// ---------------------------------------------------------------- QR (DC1.)

String encodeQr(Uint8List credentialBytes, Uint8List collegeSig, int ts, Uint8List deviceSig) {
  final env = cborArray([cborBytes(credentialBytes), cborBytes(collegeSig), cborUint(ts), cborBytes(deviceSig)]);
  return 'DC1.${toBase64Url(env)}';
}

/// What the student app calls every refresh: sign (ts, credential) with the device key and assemble
/// the QR text. [ts] is the phone's clock plus its stored server-time offset, in unix seconds.
Future<String> buildScanQr(SignedCredential credential, int ts, DeviceSigner signer) async {
  final deviceSig = await signer.signRaw(deviceSigningInput(ts, credential.credentialBytes));
  if (deviceSig.length != 64) {
    throw StateError('DeviceSigner must return raw 64-byte r||s (convert DER with ecdsaDerToRaw)');
  }
  return encodeQr(credential.credentialBytes, credential.collegeSig, ts, deviceSig);
}

class _Envelope {
  const _Envelope(this.credentialBytes, this.collegeSig, this.ts, this.deviceSig);
  final Uint8List credentialBytes;
  final Uint8List collegeSig;
  final int ts;
  final Uint8List deviceSig;
}

final RegExp _qrPrefix = RegExp(r'^DC([0-9]{1,3})\.');

_Envelope _parseEnvelope(String text) {
  if (text.length > _maxQrChars) throw const _Failure(ScanFailure.malformed);
  final m = _qrPrefix.firstMatch(text);
  if (m == null) throw const _Failure(ScanFailure.malformed);
  if (int.parse(m.group(1)!) != formatVersion) throw const _Failure(ScanFailure.unsupportedVersion);

  final body = fromBase64Url(text.substring(m.end));
  if (body == null) throw const _Failure(ScanFailure.malformed);
  final arr = _tryDecode(body);
  if (arr is! List<Object> || arr.length != 4) throw const _Failure(ScanFailure.malformed);
  final cred = arr[0];
  final collegeSig = arr[1];
  final ts = arr[2];
  final deviceSig = arr[3];
  if (cred is! Uint8List ||
      collegeSig is! Uint8List ||
      collegeSig.length != 64 ||
      ts is! int ||
      deviceSig is! Uint8List ||
      deviceSig.length != 64) {
    throw const _Failure(ScanFailure.malformed);
  }
  return _Envelope(cred, collegeSig, ts, deviceSig);
}

/// Runs the algorithm in docs/credential-spec.md section 9, in that order, and stops at the first
/// failure.
///
/// [now] is the scanner's corrected clock in unix seconds. [keys] maps key version to the college's
/// compressed public key. [revoked] must come from a list that already passed
/// [verifyRevocationList].
ScanOutcome verifyScan(
  String text, {
  required int now,
  required Map<int, Uint8List> keys,
  Iterable<RevocationEntry> revoked = const [],
  int maxAgeS = defaultMaxAgeS,
  int maxFutureS = defaultMaxFutureS,
}) {
  try {
    final env = _parseEnvelope(text);
    final credential = _parseCredential(env.credentialBytes);

    final collegeKey = keys[credential.kv];
    if (collegeKey == null) throw const _Failure(ScanFailure.unknownKeyVersion);
    if (!verifyEcdsa(collegeKey, collegeSigningInput(env.credentialBytes), env.collegeSig)) {
      throw const _Failure(ScanFailure.badCollegeSig);
    }
    if (!verifyEcdsa(credential.dpk, deviceSigningInput(env.ts, env.credentialBytes), env.deviceSig)) {
      throw const _Failure(ScanFailure.badDeviceSig);
    }

    final age = now - env.ts;
    if (age > maxAgeS || -age > maxFutureS) throw const _Failure(ScanFailure.clockMismatch);
    if (now >= credential.exp) throw const _Failure(ScanFailure.expired);
    if (revoked.any((e) => e.sid == credential.sid && credential.iat <= e.revokedAt)) {
      throw const _Failure(ScanFailure.revoked);
    }
    return ScanAccepted(credential, env.ts);
  } on _Failure catch (f) {
    return ScanRejected(f.failure);
  }
}

// ---------------------------------------------------------------- revocation list (DR1.)

final RegExp _revocationPrefix = RegExp(r'^DR([0-9]{1,3})\.');

/// Verifies a downloaded list. The caller replaces its stored list only on [RevocationAccepted]
/// with a higher `seq` than the one it already holds.
RevocationOutcome verifyRevocationList(String text, Map<int, Uint8List> keys) {
  const malformed = RevocationRejected(RevocationFailure.malformed);

  final m = _revocationPrefix.firstMatch(text);
  if (m == null) return malformed;
  if (int.parse(m.group(1)!) != formatVersion) return const RevocationRejected(RevocationFailure.unsupportedVersion);
  final body = fromBase64Url(text.substring(m.end));
  if (body == null) return malformed;

  final arr = _tryDecode(body);
  if (arr is! List<Object> || arr.length != 2) return malformed;
  final payloadBytes = arr[0];
  final sig = arr[1];
  if (payloadBytes is! Uint8List || sig is! Uint8List || sig.length != 64) return malformed;
  final payload = _tryDecode(payloadBytes);
  if (payload is! Map<int, Object>) return malformed;

  if (payload[0] != formatVersion) return const RevocationRejected(RevocationFailure.unsupportedVersion);
  final kv = payload[1];
  final seq = payload[2];
  final iat = payload[3];
  final rawEntries = payload[4];
  if (kv is! int || seq is! int || iat is! int || rawEntries is! List<Object>) return malformed;
  final entries = <RevocationEntry>[];
  for (final e in rawEntries) {
    if (e is! List<Object> || e.length != 2) return malformed;
    final sid = e[0];
    final at = e[1];
    if (sid is! int || at is! int) return malformed;
    entries.add(RevocationEntry(sid, at));
  }

  final key = keys[kv];
  if (key == null) return const RevocationRejected(RevocationFailure.unknownKeyVersion);
  if (!verifyEcdsa(key, concatBytes([ctxRevo, payloadBytes]), sig)) {
    return const RevocationRejected(RevocationFailure.badSignature);
  }
  return RevocationAccepted(RevocationList(kv: kv, seq: seq, iat: iat, entries: entries));
}

// ---------------------------------------------------------------- key set

/// Parses the key set document (spec section 8) into key version -> compressed public key.
/// Throws [FormatException] if it is malformed.
Map<int, Uint8List> parseKeySet(Map<String, Object?> doc) {
  if (doc['v'] != 1) throw const FormatException('unsupported key set version');
  final current = doc['current'];
  final keys = doc['keys'];
  if (current is! int || keys is! List) throw const FormatException('malformed key set');
  final out = <int, Uint8List>{};
  for (final k in keys) {
    if (k is! Map) throw const FormatException('malformed key entry');
    final kv = k['kv'];
    final pub = k['pub'] is String ? fromBase64Url(k['pub'] as String) : null;
    if (kv is! int || k['alg'] != 'ES256' || pub == null || pub.length != 33) {
      throw FormatException('bad key entry kv=$kv');
    }
    out[kv] = pub;
  }
  if (!out.containsKey(current)) throw const FormatException('current key missing from key set');
  return out;
}
