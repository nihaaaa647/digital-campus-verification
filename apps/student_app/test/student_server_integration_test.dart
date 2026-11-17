// The Dart student app against the real local server: the same handlers, SQL and database that the Edge
// Functions use (supabase/functions/dev/serve.ts). Skipped unless a server is running and its address is given:
//
//   cd supabase/functions && MEMORY=1 PORT=8790 npm run dev:server
//   cd apps/student_app
//   DCID_STUDENT_SERVER_URL=http://127.0.0.1:8790 flutter test test/student_server_integration_test.dart
//
// (PowerShell: $env:DCID_STUDENT_SERVER_URL = '...'; flutter test test/student_server_integration_test.dart)
// It signs in as roster students from supabase/seed.sql (their email is the roll number at vnrvjiet.in), and
// as a roll number the roster does not list.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/src/student_api.dart';

import 'support/fake_campus_server.dart';
import 'support/fake_keystore.dart';

final String? _url = Platform.environment['DCID_STUDENT_SERVER_URL'];

/// A phone's Keystore, in software: signs with a known test key.
class _SoftwareSigner implements DeviceSigner {
  _SoftwareSigner(this._private);

  final Uint8List _private;

  @override
  Future<Uint8List> signRaw(Uint8List message) async => signEcdsa(_private, message);
}

/// Asks for a code, waiting out the server's 30-second pause between codes if an earlier run just asked.
Future<String> _codeFor(StudentApi api, String email) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final sent = await api.requestOtp(email);
      return sent.devOtp ?? fail('the server is not in demo mode (DEMO_OTP=0): it does not show codes');
    } on ApiException catch (e) {
      if (e.failure != ApiFailure.wait) rethrow;
      await Future<void>.delayed(Duration(seconds: (e.retryAfterS ?? 30) + 1));
    }
  }
  fail('could not get a code');
}

Map<int, Uint8List> _collegeKeys() {
  final vectors = jsonDecode(File('../../spec/test-vectors/v1.json').readAsStringSync()) as Map<String, Object?>;
  return parseKeySet(vectors['keyset_json']! as Map<String, Object?>);
}

void main() {
  final skip = _url == null ? 'set DCID_STUDENT_SERVER_URL to a running local server' : null;

  test('a student signs up, is approved, gets a pass bound to their key, and a scanner accepts it', () async {
    final api = StudentApi(Uri.parse(_url!));
    addTearDown(api.close);

    // Sign in. Anita is on the roster in supabase/seed.sql.
    const email = '25071a0002@vnrvjiet.in';
    final signedIn = await api.verifyOtp(email, await _codeFor(api, email));
    expect(signedIn.student.name, 'Anita Rao');
    expect(signedIn.student.rollNumber, '25071A0002');

    // Not enrolled yet, so no pass can be had.
    final before = await api.enrolmentStatus(signedIn.token);
    expect(before.student.rollNumber, '25071A0002');
    expect(before.state, EnrolmentState.none);
    expect(before.profileComplete, isTrue, reason: 'Anita is on the college roster, so name, branch and year are already known');

    final key = publicKeyOf(devAPrivate);
    {
      await expectLater(api.issueCredential(signedIn.token, key), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.notApproved)));
    }

    // Enrol with a phone number and a photo. Signing in with the roll-number email already proved who this is,
    // so there is no waiting for an admin.
    final state = await api.enrol(signedIn.token, phone: '+91 98765 43210', photo: testPhoto(seed: DateTime.now().millisecondsSinceEpoch % 1000));
    expect(state, EnrolmentState.approved);
    expect((await api.enrolmentStatus(signedIn.token)).state, EnrolmentState.approved);

    // The pass comes back signed by the college, naming this phone's key.
    final issued = await api.issueCredential(signedIn.token, key);
    final signed = parseSignedCredential(issued.signedCredential)!;
    final credential = decodeCredential(signed.credentialBytes);
    expect(credential.name, 'Anita Rao');
    expect(credential.roll, '25071A0002');
    expect(credential.branch, 'ECE');
    expect(credential.year, 3);
    expect(credential.dpk, key);
    expect(credential.exp - credential.iat, 180 * 86400);
    expect((issued.serverTimeS - DateTime.now().millisecondsSinceEpoch ~/ 1000).abs(), lessThan(60));

    // A QR signed by that key is accepted by the scanner's own check, against the college key set.
    final ts = issued.serverTimeS + 1;
    final qr = await buildScanQr(signed, ts, _SoftwareSigner(devAPrivate));
    final scan = verifyScan(qr, now: ts, keys: _collegeKeys());
    expect(scan, isA<ScanAccepted>());
    expect((scan as ScanAccepted).credential.name, 'Anita Rao');

    // A copy made by someone with a different key is not.
    final stolen = await buildScanQr(signed, ts, _SoftwareSigner(devBPrivate));
    expect(verifyScan(stolen, now: ts, keys: _collegeKeys()), isNot(isA<ScanAccepted>()));

    // A second phone gets its own pass (the first phone's device is revoked on the server).
    final second = await api.issueCredential(signedIn.token, publicKeyOf(devBPrivate));
    expect(decodeCredential(parseSignedCredential(second.signedCredential)!.credentialBytes).dpk, publicKeyOf(devBPrivate));

    // Signing out ends the login.
    await api.signOut(signedIn.token);
    await expectLater(api.enrolmentStatus(signedIn.token), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.unauthorized)));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a roll number the roster does not list signs up, gives its profile, and is approved on the spot', () async {
    final api = StudentApi(Uri.parse(_url!));
    addTearDown(api.close);
    const email = '26071a9z99@vnrvjiet.in';
    final signedIn = await api.verifyOtp(email, await _codeFor(api, email));
    expect(signedIn.student.rollNumber, '26071A9Z99');

    final info = await api.enrolmentStatus(signedIn.token);
    expect(info.profileComplete, isFalse);
    expect(info.state, EnrolmentState.none);

    await expectLater(
      api.enrol(signedIn.token, phone: '+919876543210', photo: testPhoto()),
      throwsA(isA<ApiException>().having((e) => e.detail, 'detail', 'bad_profile')),
    );
    final state = await api.enrol(
      signedIn.token,
      phone: '+919876543210',
      photo: testPhoto(seed: 5),
      profile: const EnrolProfile(name: 'Integration Student', branch: 'cse-ds', year: 2),
    );
    expect(state, EnrolmentState.approved);
    expect((await api.enrolmentStatus(signedIn.token)).profileComplete, isTrue);

    final key = publicKeyOf(devAPrivate);
    final issued = await api.issueCredential(signedIn.token, key);
    final signed = parseSignedCredential(issued.signedCredential)!;
    final credential = decodeCredential(signed.credentialBytes);
    expect(credential.name, 'Integration Student');
    expect(credential.branch, 'CSE-DS');
    expect(credential.roll, '26071A9Z99');
    final ts = issued.serverTimeS + 1;
    final qr = await buildScanQr(signed, ts, _SoftwareSigner(devAPrivate));
    expect(verifyScan(qr, now: ts, keys: _collegeKeys()), isA<ScanAccepted>());
    await api.signOut(signedIn.token);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('the failures the app explains', () async {
    final api = StudentApi(Uri.parse(_url!));
    addTearDown(api.close);

    await expectLater(api.requestOtp('stranger@vnrvjiet.in'), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.notOnRoster)));
    await expectLater(api.requestOtp('not-an-email'), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.badEmail)));
    await expectLater(api.verifyOtp('25071a0003@vnrvjiet.in', '000000'), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.wrongCode)));
    await expectLater(api.enrolmentStatus('x' * 43), throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.unauthorized)));
  }, skip: skip);

  test('a photo the server refuses comes back as bad input', () async {
    final api = StudentApi(Uri.parse(_url!));
    addTearDown(api.close);
    const email = '25071a0004@vnrvjiet.in';
    final signedIn = await api.verifyOtp(email, await _codeFor(api, email));

    await expectLater(
      api.enrol(signedIn.token, phone: '+919876543210', photo: Uint8List.fromList(List.filled(2000, 7))),
      throwsA(isA<ApiException>().having((e) => e.failure, 'failure', ApiFailure.badInput).having((e) => e.detail, 'detail', 'bad_photo')),
    );
    await expectLater(
      api.enrol(signedIn.token, phone: '12', photo: testPhoto()),
      throwsA(isA<ApiException>().having((e) => e.detail, 'detail', 'bad_phone')),
    );
    await api.signOut(signedIn.token);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
