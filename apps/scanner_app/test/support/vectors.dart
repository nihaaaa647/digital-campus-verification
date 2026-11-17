import 'dart:convert';
import 'dart:io';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';

/// The shared test vectors (spec/test-vectors/v1.json), found by walking up from the working directory.
class Vectors {
  Vectors._(this.json);

  final Map<String, dynamic> json;

  static Vectors load() {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final f = File('${dir.path}/spec/test-vectors/v1.json');
      if (f.existsSync()) return Vectors._(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
      dir = dir.parent;
    }
    throw StateError('spec/test-vectors/v1.json not found above ${Directory.current.path}');
  }

  int get referenceNow => json['reference_now'] as int;
  List<dynamic> get verifyCases => json['verify_cases'] as List;

  late final Map<int, Uint8List> collegePublic = {
    for (final k in json['keys']['college']) k['kv'] as int: hexToBytes(k['public_hex'] as String),
  };
  late final Map<int, Uint8List> collegePrivate = {
    for (final k in json['keys']['college']) k['kv'] as int: hexToBytes(k['private_hex'] as String),
  };
  late final Map<String, Uint8List> devicePrivate = {
    for (final k in json['keys']['devices']) k['name'] as String: hexToBytes(k['private_hex'] as String),
  };

  Map<int, Uint8List> keysFor(List<dynamic> kvs) => {for (final kv in kvs) kv as int: collegePublic[kv]!};

  Map<String, dynamic> credentialFields(String id) =>
      ((json['credentials'] as List).firstWhere((c) => c['id'] == id)['fields']) as Map<String, dynamic>;

  /// A fresh QR for [sid], signed by the college key and by test device key dev_a at time [ts].
  /// Everything but the student's identity comes from the `student_ok` credential.
  Future<String> makeQr({required int ts, int sid = 1042, String roll = '25071A0001', String name = 'Sample Student'}) async {
    final f = credentialFields('student_ok');
    final credential = Credential(
      v: f['v'] as int,
      kv: f['kv'] as int,
      sid: sid,
      roll: roll,
      name: name,
      branch: f['branch'] as String,
      year: f['year'] as int,
      pass: f['pass'] as int,
      photo: hexToBytes(f['photo_hex'] as String),
      dpk: publicKeyOf(devicePrivate['dev_a']!),
      iat: f['iat'] as int,
      exp: f['exp'] as int,
    );
    final bytes = encodeCredential(credential);
    final collegeSig = signEcdsa(collegePrivate[credential.kv]!, collegeSigningInput(bytes));
    return buildScanQr(SignedCredential(bytes, collegeSig), ts, _SoftwareSigner(devicePrivate['dev_a']!));
  }
}

class _SoftwareSigner implements DeviceSigner {
  _SoftwareSigner(this.privateKey);

  final Uint8List privateKey;

  @override
  Future<Uint8List> signRaw(Uint8List message) async => signEcdsa(privateKey, message);
}
