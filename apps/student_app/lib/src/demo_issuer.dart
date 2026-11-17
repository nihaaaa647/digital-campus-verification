import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';

import 'pass_store.dart';

/// The college test key kv 1 from spec/test-vectors/v1.json. It is public, in the repository, and only
/// ever used here. A scanner that trusts it trusts every copy of this app.
final Uint8List _testCollegePrivateKey = hexToBytes('25d088b1661ba51e91af13d9eec1309cd3397e9a0181e0311c285fdaff68c13b');

/// Debug builds only. Stands in for `issue-credential` so the pass screen can be driven end to end
/// before that endpoint exists: it signs a made-up student's credential with the test college key.
/// The screen offers it only under `kDebugMode`, so release builds never reach this code.
StoredPass issueDemoPass({required Uint8List devicePublicKey, required int nowS}) {
  final credential = Credential(
    v: formatVersion,
    kv: 1,
    sid: 900001,
    roll: 'DEMO0001',
    name: 'Demo Student',
    branch: 'CSE',
    year: 3,
    pass: PassType.student.code,
    photo: Uint8List(16),
    dpk: devicePublicKey,
    iat: nowS,
    exp: nowS + 30 * 24 * 60 * 60,
  );
  final bytes = encodeCredential(credential);
  final collegeSig = signEcdsa(_testCollegePrivateKey, collegeSigningInput(bytes));
  return StoredPass(signedCredential: encodeSignedCredential(bytes, collegeSig), serverOffsetS: 0);
}
