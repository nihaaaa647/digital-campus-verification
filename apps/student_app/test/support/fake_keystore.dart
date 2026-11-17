import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:student_app/src/keystore_signer.dart';

/// Test keys from spec/test-vectors/v1.json.
final Uint8List devAPrivate = hexToBytes('0c9b9c3ee8d2ab86c0a470977de8042d349281f0bdcf3e7d037b9052fbb4e06a');
final Uint8List devBPrivate = hexToBytes('18656ac42db4259af0f9dec8597eb26b3e8cadd4adb0cb8975172f662a28dfde');
final Uint8List collegePublicKv1 = publicKeyOf(hexToBytes('25d088b1661ba51e91af13d9eec1309cd3397e9a0181e0311c285fdaff68c13b'));

final Uint8List _spkiHeader = hexToBytes('3059301306072a8648ce3d020106082a8648ce3d030107034200');

/// What `PublicKey.getEncoded()` returns on Android for a P-256 key: a 91-byte SubjectPublicKeyInfo.
Uint8List spkiOf(Uint8List privateKey) {
  final d = BigInt.parse(bytesToHex(privateKey), radix: 16);
  final point = (ECCurve_secp256r1().G * d)!.getEncoded(false);
  return Uint8List.fromList([..._spkiHeader, ...point]);
}

Uint8List _derInteger(Uint8List v32) {
  var i = 0;
  while (i < 31 && v32[i] == 0) {
    i++;
  }
  var body = v32.sublist(i);
  if (body[0] & 0x80 != 0) body = Uint8List.fromList([0, ...body]);
  return Uint8List.fromList([0x02, body.length, ...body]);
}

/// What `Signature.sign()` returns on Android: `SEQUENCE { INTEGER r, INTEGER s }`.
Uint8List derOf(Uint8List raw) {
  final r = _derInteger(raw.sublist(0, 32));
  final s = _derInteger(raw.sublist(32));
  return Uint8List.fromList([0x30, r.length + s.length, ...r, ...s]);
}

/// Stands in for `KeystoreChannel.kt`: the same calls and the same encodings (X.509 key, DER
/// signature), with a software key. [KeystoreSigner] runs unchanged on top of it.
class FakeKeystore {
  FakeKeystore({Uint8List? privateKey, this.hasKey = true, this.security = 'tee'}) : privateKey = privateKey ?? devAPrivate;

  Uint8List privateKey;
  bool hasKey;
  String security;

  /// When set, every call fails with this error, as when the Keystore service is unavailable.
  PlatformException? failWith;

  /// When set, `sign` returns this instead of a DER signature.
  Uint8List? signatureOverride;

  int signCount = 0;

  Uint8List get publicKey => publicKeyOf(privateKey);

  void install([String channel = keystoreChannelName]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), _handle);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), null));
  }

  Future<Object?> _handle(MethodCall call) async {
    final failure = failWith;
    if (failure != null) throw failure;
    switch (call.method) {
      case 'key':
        final create = (call.arguments as Map)['create'] == true;
        if (!hasKey) {
          if (!create) return null;
          hasKey = true;
        }
        return {'publicKey': spkiOf(privateKey), 'security': security};
      case 'sign':
        if (!hasKey) throw PlatformException(code: 'no_key', message: 'the device key does not exist');
        signCount++;
        final message = (call.arguments as Map)['message'] as Uint8List;
        return signatureOverride ?? derOf(signEcdsa(privateKey, message));
      case 'deleteKey':
        hasKey = false;
        return null;
    }
    throw MissingPluginException(call.method);
  }
}
