// Runs the shared test vectors (spec/test-vectors/v1.json) against the Dart implementation.
//   dart test        (from packages/credential_core)
// The TypeScript implementation runs the same file from supabase/functions.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';
import 'package:pointycastle/export.dart' show ECCurve_secp256r1;
import 'package:test/test.dart';

Map<String, dynamic> loadVectors() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/spec/test-vectors/v1.json');
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    dir = dir.parent;
  }
  throw StateError('spec/test-vectors/v1.json not found above ${Directory.current.path}');
}

class SoftwareSigner implements DeviceSigner {
  SoftwareSigner(this.privateKey);
  final Uint8List privateKey;

  @override
  Future<Uint8List> signRaw(Uint8List message) async => signEcdsa(privateKey, message);
}

void main() {
  final v = loadVectors();
  final collegePub = {for (final k in v['keys']['college']) k['kv'] as int: hexToBytes(k['public_hex'] as String)};
  final collegePriv = {for (final k in v['keys']['college']) k['kv'] as int: hexToBytes(k['private_hex'] as String)};
  final devicePriv = {for (final k in v['keys']['devices']) k['name'] as String: hexToBytes(k['private_hex'] as String)};
  Map<int, Uint8List> pubsFor(List<dynamic> kvs) => {for (final kv in kvs) kv as int: collegePub[kv]!};

  Credential toCredential(Map<String, dynamic> f) => Credential(
        v: f['v'] as int,
        kv: f['kv'] as int,
        sid: f['sid'] as int,
        roll: f['roll'] as String,
        name: f['name'] as String,
        branch: f['branch'] as String,
        year: f['year'] as int,
        pass: f['pass'] as int,
        photo: hexToBytes(f['photo_hex'] as String),
        dpk: hexToBytes(f['dpk_hex'] as String),
        iat: f['iat'] as int,
        exp: f['exp'] as int,
      );

  test('context strings', () {
    expect(bytesToHex(ctxCred), v['contexts']['cred_hex']);
    expect(bytesToHex(ctxScan), v['contexts']['scan_hex']);
    expect(bytesToHex(ctxRevo), v['contexts']['revo_hex']);
  });

  test('public keys derive from the test private keys', () {
    for (final k in [...v['keys']['college'], ...v['keys']['devices']]) {
      expect(bytesToHex(publicKeyOf(hexToBytes(k['private_hex'] as String))), k['public_hex']);
    }
  });

  test('key set document parses to the same keys', () {
    final keys = parseKeySet(Map<String, Object?>.from(v['keyset_json'] as Map));
    expect(keys.keys.toSet(), {1, 2});
    keys.forEach((kv, pub) => expect(bytesToHex(pub), bytesToHex(collegePub[kv]!)));
  });

  group('credentials', () {
    for (final c in v['credentials']) {
      test('${c['id']}: encoding, signature and delivery blob', () {
        final fields = toCredential(c['fields'] as Map<String, dynamic>);
        final bytes = encodeCredential(fields);
        expect(bytesToHex(bytes), c['cbor_hex'], reason: 'deterministic CBOR must match byte for byte');

        final collegeSig = hexToBytes(c['college_sig_hex'] as String);
        expect(verifyEcdsa(collegePub[fields.kv]!, collegeSigningInput(bytes), collegeSig), isTrue);
        expect(bytesToHex(signEcdsa(collegePriv[fields.kv]!, collegeSigningInput(bytes))), c['college_sig_hex'],
            reason: 'RFC 6979 signatures must match the generator byte for byte');

        expect(encodeSignedCredential(bytes, collegeSig), c['signed_text']);
        final parsed = parseSignedCredential(c['signed_text'] as String)!;
        expect(bytesToHex(parsed.credentialBytes), c['cbor_hex']);
        expect(bytesToHex(parsed.collegeSig), c['college_sig_hex']);

        if (fields.v == 1) {
          final decoded = decodeCredential(bytes);
          expect(encodeCredential(decoded), bytes);
          expect(decoded.name, fields.name);
          expect(decoded.sid, fields.sid);
        }
      });
    }
  });

  test('ok_basic is reproduced byte for byte by buildScanQr with the device key', () async {
    final c = (v['credentials'] as List).firstWhere((x) => x['id'] == 'student_ok');
    final qr = await buildScanQr(
      SignedCredential(hexToBytes(c['cbor_hex'] as String), hexToBytes(c['college_sig_hex'] as String)),
      (v['reference_now'] as int) - 5,
      SoftwareSigner(devicePriv['dev_a']!),
    );
    final expected = (v['verify_cases'] as List).firstWhere((x) => x['id'] == 'ok_basic')['qr'];
    expect(qr, expected);
  });

  group('revocation cases', () {
    for (final c in v['revocation_cases']) {
      test(c['id'] as String, () {
        final out = verifyRevocationList(c['encoded'] as String, pubsFor(c['keyset'] as List));
        final expect_ = c['expect'] as Map<String, dynamic>;
        if (expect_['result'] == 'OK') {
          expect(out, isA<RevocationAccepted>());
          final list = (out as RevocationAccepted).list;
          expect(list.seq, expect_['seq']);
          expect(list.iat, expect_['iat']);
          expect([for (final e in list.entries) [e.sid, e.revokedAt]], expect_['entries']);
        } else {
          expect(out, isA<RevocationRejected>());
          expect((out as RevocationRejected).failure.code, expect_['result']);
        }
      });
    }
  });

  group('verify cases', () {
    final policy = v['policy'] as Map<String, dynamic>;
    for (final c in v['verify_cases']) {
      test(c['id'] as String, () {
        final keys = pubsFor(c['keyset'] as List);
        var revoked = <RevocationEntry>[];
        if (c['revocation'] != null) {
          final list = verifyRevocationList(c['revocation'] as String, keys);
          expect(list, isA<RevocationAccepted>(), reason: 'the list attached to a verify case must itself be valid');
          revoked = (list as RevocationAccepted).list.entries;
        }
        final out = verifyScan(
          c['qr'] as String,
          now: c['now'] as int,
          keys: keys,
          revoked: revoked,
          maxAgeS: policy['max_age_s'] as int,
          maxFutureS: policy['max_future_s'] as int,
        );
        final want = c['expect'] as Map<String, dynamic>;
        if (want['result'] == 'OK') {
          expect(out, isA<ScanAccepted>(), reason: 'expected OK, got ${out is ScanRejected ? out.failure.code : 'OK'}');
          final got = (out as ScanAccepted).credential;
          final x = want['credential'] as Map<String, dynamic>;
          expect(got.sid, x['sid']);
          expect(got.roll, x['roll']);
          expect(got.name, x['name']);
          expect(got.branch, x['branch']);
          expect(got.year, x['year']);
          expect(got.pass, x['pass']);
          expect(got.kv, x['kv']);
          expect(got.exp, x['exp']);
        } else {
          expect(out, isA<ScanRejected>());
          expect((out as ScanRejected).failure.code, want['result']);
        }
      });
    }
  });

  group('DER and key encodings', () {
    // Minimal DER writer, only for building test input.
    Uint8List derInt(Uint8List be32) {
      var i = 0;
      while (i < 31 && be32[i] == 0) {
        i++;
      }
      var body = be32.sublist(i);
      if (body[0] & 0x80 != 0) body = Uint8List.fromList([0, ...body]);
      return Uint8List.fromList([0x02, body.length, ...body]);
    }

    Uint8List toDer(Uint8List raw) {
      final content = [...derInt(raw.sublist(0, 32)), ...derInt(raw.sublist(32))];
      return Uint8List.fromList([0x30, content.length, ...content]);
    }

    test('ecdsaDerToRaw round-trips every signature in the vectors', () {
      var checked = 0;
      for (final c in v['credentials']) {
        final raw = hexToBytes(c['college_sig_hex'] as String);
        expect(ecdsaDerToRaw(toDer(raw)), raw);
        checked++;
      }
      expect(checked, greaterThan(0));
    });

    test('ecdsaDerToRaw handles short integers (leading zeros stripped)', () {
      final raw = Uint8List(64)
        ..[31] = 0x05
        ..[63] = 0x80;
      expect(ecdsaDerToRaw(toDer(raw)), raw);
    });

    test('ecdsaDerToRaw rejects garbage', () {
      expect(() => ecdsaDerToRaw(Uint8List.fromList([0x31, 0x00])), throwsFormatException);
      expect(() => ecdsaDerToRaw(Uint8List.fromList([0x30, 0x02, 0x02, 0x00])), throwsFormatException);
      final good = toDer(hexToBytes(v['credentials'][0]['college_sig_hex'] as String));
      expect(() => ecdsaDerToRaw(Uint8List.fromList([...good, 0x00])), throwsFormatException);
    });

    test('Keystore SubjectPublicKeyInfo and uncompressed points compress to the vector key', () {
      final spkiPrefix = hexToBytes('3059301306072a8648ce3d020106082a8648ce3d030107034200');
      for (final k in v['keys']['devices']) {
        final compressed = hexToBytes(k['public_hex'] as String);
        final uncompressed = decompress(compressed);
        expect(uncompressed.length, 65);
        expect(compressPublicKey(uncompressed), compressed);
        expect(compressedPublicKeyFromSpki(Uint8List.fromList([...spkiPrefix, ...uncompressed])), compressed);
      }
    });
  });

  group('CBOR strictness', () {
    final good = hexToBytes((v['credentials'] as List)[0]['cbor_hex'] as String);

    test('accepts the canonical credential', () {
      expect(decodeCredential(good).sid, 1042);
    });

    for (final entry in {
      'indefinite-length array': '9f01ff',
      'tag': 'c101',
      'negative integer': '20',
      'float': 'f93c00',
      'simple value': 'f5',
      'duplicate map key': 'a200010001',
      'text map key': 'a1616101',
      'integer above 2^53 - 1': '1b0020000000000000',
      'truncated byte string': '4401',
      'invalid UTF-8': '62c328',
    }.entries) {
      test('rejects ${entry.key}', () {
        expect(() => decodeCredential(hexToBytes(entry.value)), throwsFormatException);
      });
    }

    test('rejects trailing bytes', () {
      expect(() => decodeCredential(Uint8List.fromList([...good, 0])), throwsFormatException);
    });
  });
}

/// Test-only helper: uncompressed point for a compressed key, using the same library as the package.
Uint8List decompress(Uint8List compressed) => ECCurve_secp256r1().curve.decodePoint(compressed)!.getEncoded(false);
