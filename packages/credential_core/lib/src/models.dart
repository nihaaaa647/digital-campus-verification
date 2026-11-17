import 'dart:typed_data';

/// Pass type, credential field 7.
enum PassType {
  student(0),
  fresher(1),
  visitor(2);

  const PassType(this.code);
  final int code;

  static PassType? fromCode(int code) {
    for (final p in values) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// A credential as decoded from the signed bytes (docs/credential-spec.md section 4).
class Credential {
  const Credential({
    required this.v,
    required this.kv,
    required this.sid,
    required this.roll,
    required this.name,
    required this.branch,
    required this.year,
    required this.pass,
    required this.photo,
    required this.dpk,
    required this.iat,
    required this.exp,
  });

  final int v;
  final int kv;
  final int sid;
  final String roll;
  final String name;
  final String branch;
  final int year;
  final int pass;
  final Uint8List photo;
  final Uint8List dpk;
  final int iat;
  final int exp;

  PassType? get passType => PassType.fromCode(pass);
}

/// Why a scan was rejected. [code] is the stable string used in the shared test vectors.
enum ScanFailure {
  malformed('MALFORMED'),
  unsupportedVersion('UNSUPPORTED_VERSION'),
  unknownKeyVersion('UNKNOWN_KEY_VERSION'),
  badCollegeSig('BAD_COLLEGE_SIG'),
  badDeviceSig('BAD_DEVICE_SIG'),
  clockMismatch('CLOCK_MISMATCH'),
  expired('EXPIRED'),
  revoked('REVOKED');

  const ScanFailure(this.code);
  final String code;
}

sealed class ScanOutcome {
  const ScanOutcome();
}

class ScanAccepted extends ScanOutcome {
  const ScanAccepted(this.credential, this.ts);
  final Credential credential;

  /// The phone's signed timestamp, unix seconds.
  final int ts;
}

class ScanRejected extends ScanOutcome {
  const ScanRejected(this.failure);
  final ScanFailure failure;
}

class RevocationEntry {
  const RevocationEntry(this.sid, this.revokedAt);
  final int sid;
  final int revokedAt;
}

class RevocationList {
  const RevocationList({required this.kv, required this.seq, required this.iat, required this.entries});
  final int kv;
  final int seq;
  final int iat;
  final List<RevocationEntry> entries;
}

enum RevocationFailure {
  malformed('MALFORMED'),
  unsupportedVersion('UNSUPPORTED_VERSION'),
  unknownKeyVersion('UNKNOWN_KEY_VERSION'),
  badSignature('BAD_SIGNATURE');

  const RevocationFailure(this.code);
  final String code;
}

sealed class RevocationOutcome {
  const RevocationOutcome();
}

class RevocationAccepted extends RevocationOutcome {
  const RevocationAccepted(this.list);
  final RevocationList list;
}

class RevocationRejected extends RevocationOutcome {
  const RevocationRejected(this.failure);
  final RevocationFailure failure;
}

/// The college-signed credential the phone stores (`DK1.` text), as two byte strings.
class SignedCredential {
  const SignedCredential(this.credentialBytes, this.collegeSig);
  final Uint8List credentialBytes;
  final Uint8List collegeSig;
}

/// Signs with the phone's hardware-backed key. The Android implementation lives in the student app
/// and wraps the Keystore, which returns DER: convert with `ecdsaDerToRaw` so that [signRaw] always
/// returns the 64-byte raw `r || s` form.
abstract interface class DeviceSigner {
  Future<Uint8List> signRaw(Uint8List message);
}
