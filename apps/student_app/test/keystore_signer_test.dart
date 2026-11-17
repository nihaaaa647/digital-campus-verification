import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/src/keystore_signer.dart';

import 'support/fake_keystore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('existingKey is null until a key is created, and never creates one', () async {
    final fake = FakeKeystore(hasKey: false)..install();
    final signer = KeystoreSigner();

    expect(await signer.existingKey(), isNull);
    expect(fake.hasKey, isFalse);

    final created = await signer.getOrCreateKey();
    expect(fake.hasKey, isTrue);
    expect(created.publicKey, fake.publicKey);
    expect((await signer.existingKey())!.publicKey, fake.publicKey);
  });

  test('turns the X.509 key into the 33-byte compressed key the credential carries', () async {
    FakeKeystore(security: 'strongbox').install();
    final key = await KeystoreSigner().getOrCreateKey();

    expect(key.publicKey.length, 33);
    expect(key.publicKey[0], anyOf(0x02, 0x03));
    expect(key.publicKey, publicKeyOf(devAPrivate));
    expect(key.security, KeySecurity.strongbox);
  });

  test('an unrecognised security level reads as unknown', () async {
    FakeKeystore(security: 'quantum').install();
    expect((await KeystoreSigner().getOrCreateKey()).security, KeySecurity.unknown);
  });

  test('signRaw returns 64-byte r||s that verifies, including DER signatures with padded integers', () async {
    final fake = FakeKeystore()..install();
    final signer = KeystoreSigner();
    var sawPaddedInteger = false;

    for (var i = 0; i < 40; i++) {
      final message = Uint8List.fromList('message number $i'.codeUnits);
      final raw = await signer.signRaw(message);
      expect(raw.length, 64);
      expect(verifyEcdsa(fake.publicKey, message, raw), isTrue, reason: 'message $i');
      if (raw[0] >= 0x80 || raw[32] >= 0x80) sawPaddedInteger = true; // DER needs a leading 0x00 for these
    }
    expect(sawPaddedInteger, isTrue, reason: 'the 40 signatures should include a DER integer with a 0x00 pad');
  });

  test('a missing key is an error on sign, not a silently generated key', () async {
    final fake = FakeKeystore(hasKey: false)..install();

    await expectLater(
      KeystoreSigner().signRaw(Uint8List(8)),
      throwsA(isA<KeystoreException>().having((e) => e.code, 'code', 'no_key')),
    );
    expect(fake.hasKey, isFalse);
  });

  test('platform failures surface as KeystoreException', () async {
    FakeKeystore()
      ..failWith = PlatformException(code: 'keystore_error', message: 'service died')
      ..install();
    final signer = KeystoreSigner();

    await expectLater(signer.existingKey(), throwsA(isA<KeystoreException>().having((e) => e.code, 'code', 'keystore_error')));
    await expectLater(signer.signRaw(Uint8List(8)), throwsA(isA<KeystoreException>()));
  });

  test('a signature that is not DER is rejected rather than passed on', () async {
    FakeKeystore()
      ..signatureOverride = Uint8List(64)
      ..install();

    await expectLater(
      KeystoreSigner().signRaw(Uint8List(8)),
      throwsA(isA<KeystoreException>().having((e) => e.code, 'code', 'bad_response')),
    );
  });

  test('deleteKey removes the key', () async {
    final fake = FakeKeystore()..install();
    await KeystoreSigner().deleteKey();
    expect(fake.hasKey, isFalse);
  });
}
