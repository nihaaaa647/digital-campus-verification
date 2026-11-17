import 'dart:async';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/src/demo_issuer.dart';
import 'package:student_app/src/keystore_signer.dart';
import 'package:student_app/src/pass_controller.dart';
import 'package:student_app/src/pass_store.dart';

import 'support/fake_keystore.dart';

const int _t0 = 1790000000;

class _Clock {
  int now = _t0;
  int call() => now;
}

/// Runs one [PassController.tick] and waits for the notification that ends it.
Future<void> _tick(PassController c) {
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  c.addListener(listener);
  c.tick();
  return done.future.timeout(const Duration(seconds: 5)).whenComplete(() => c.removeListener(listener));
}

ScanOutcome _scan(String qr, int now) => verifyScan(qr, now: now, keys: {1: collegePublicKv1});

int _sidOf(ScanOutcome outcome) => (outcome as ScanAccepted).credential.sid;

Future<PassController> _readyController(FakeKeystore fake, _Clock clock, {int serverOffsetS = 0}) async {
  final store = MemoryPassStore(StoredPass(
    signedCredential: issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0).signedCredential,
    serverOffsetS: serverOffsetS,
  ));
  final load = await openPass(store, KeystoreSigner(), phoneNowS: clock.call);
  expect(load.problem, isNull);
  addTearDown(load.controller!.dispose);
  return load.controller!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('openPass', () {
    test('nothing stored', () async {
      FakeKeystore().install();
      final load = await openPass(MemoryPassStore(), KeystoreSigner(), phoneNowS: _Clock().call);
      expect(load.problem, PassProblem.notActivated);
    });

    test('stored text that is not a credential', () async {
      FakeKeystore().install();
      for (final text in ['garbage', 'DK1.', 'DK1.AAAA', 'DC1.AAAA']) {
        final store = MemoryPassStore(StoredPass(signedCredential: text, serverOffsetS: 0));
        expect((await openPass(store, KeystoreSigner(), phoneNowS: _Clock().call)).problem, PassProblem.corrupt, reason: text);
      }
    });

    test('credential whose signed bytes are not a credential', () async {
      FakeKeystore().install();
      final text = encodeSignedCredential(Uint8List.fromList([1, 2, 3]), Uint8List(64));
      final store = MemoryPassStore(StoredPass(signedCredential: text, serverOffsetS: 0));
      expect((await openPass(store, KeystoreSigner(), phoneNowS: _Clock().call)).problem, PassProblem.corrupt);
    });

    test('this phone has no device key', () async {
      final fake = FakeKeystore(hasKey: false)..install();
      final pass = issueDemoPass(devicePublicKey: publicKeyOf(devAPrivate), nowS: _t0);
      final load = await openPass(MemoryPassStore(pass), KeystoreSigner(), phoneNowS: _Clock().call);
      expect(load.problem, PassProblem.deviceKeyMissing);
      expect(fake.hasKey, isFalse, reason: 'opening a pass must not create a key');
    });

    test('the device key is not the one the credential names', () async {
      FakeKeystore(privateKey: devBPrivate).install();
      final pass = issueDemoPass(devicePublicKey: publicKeyOf(devAPrivate), nowS: _t0);
      final load = await openPass(MemoryPassStore(pass), KeystoreSigner(), phoneNowS: _Clock().call);
      expect(load.problem, PassProblem.deviceKeyChanged);
    });

    test('the Keystore does not answer', () async {
      FakeKeystore()
        ..failWith = PlatformException(code: 'keystore_error')
        ..install();
      final pass = issueDemoPass(devicePublicKey: publicKeyOf(devAPrivate), nowS: _t0);
      final load = await openPass(MemoryPassStore(pass), KeystoreSigner(), phoneNowS: _Clock().call);
      expect(load.problem, PassProblem.keystoreUnavailable);
    });

    test('expired, judged on the server-corrected clock', () async {
      FakeKeystore().install();
      final pass = issueDemoPass(devicePublicKey: publicKeyOf(devAPrivate), nowS: _t0);
      final exp = decodeCredential(parseSignedCredential(pass.signedCredential)!.credentialBytes).exp;

      final clock = _Clock()..now = exp - 1;
      expect((await openPass(MemoryPassStore(pass), KeystoreSigner(), phoneNowS: clock.call)).problem, isNull);

      clock.now = exp;
      expect((await openPass(MemoryPassStore(pass), KeystoreSigner(), phoneNowS: clock.call)).problem, PassProblem.expired);

      // Phone clock 20 s slow, server offset +20: the corrected time is already past exp.
      clock.now = exp - 20;
      final slow = StoredPass(signedCredential: pass.signedCredential, serverOffsetS: 20);
      expect((await openPass(MemoryPassStore(slow), KeystoreSigner(), phoneNowS: clock.call)).problem, PassProblem.expired);
    });
  });

  group('PassController', () {
    test('first QR is signed by the device key and a scanner accepts it', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);

      expect(c.qr, isNull);
      await _tick(c);

      final qr = c.qr!;
      expect(qr, startsWith('DC1.'));
      final outcome = _scan(qr, clock.now);
      expect(outcome, isA<ScanAccepted>());
      expect((outcome as ScanAccepted).ts, clock.now);
      expect(outcome.credential.roll, 'DEMO0001');
      expect(c.fault, isNull);
      expect(c.secondsLeft, qrRefreshS);
    });

    test('the QR stays for 30 s, then is re-signed with a new timestamp', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);
      await _tick(c);
      final first = c.qr!;
      expect(fake.signCount, 1);

      clock.now = _t0 + 29;
      await _tick(c);
      expect(c.qr, first, reason: 'no new signature before 30 s');
      expect(c.secondsLeft, 1);
      expect(fake.signCount, 1);

      clock.now = _t0 + 30;
      await _tick(c);
      expect(c.qr, isNot(first));
      expect(fake.signCount, 2);
      expect(_scan(c.qr!, clock.now), isA<ScanAccepted>());
      expect((_scan(c.qr!, clock.now) as ScanAccepted).ts, _t0 + 30);
      expect(c.secondsLeft, qrRefreshS);
    });

    test('a QR that was just replaced is still accepted for 45 s and rejected after', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);
      await _tick(c);
      final qr = c.qr!;

      expect(_scan(qr, _t0 + 45), isA<ScanAccepted>());
      expect((_scan(qr, _t0 + 46) as ScanRejected).failure, ScanFailure.clockMismatch);
    });

    test('ts uses the phone clock plus the stored server offset', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock, serverOffsetS: 7);
      await _tick(c);

      expect(c.nowS, _t0 + 7);
      expect((_scan(c.qr!, _t0 + 7) as ScanAccepted).ts, _t0 + 7);
      expect(c.clockSuspect, isFalse);
    });

    test('warns when the clock is more than 10 s from the server', () async {
      final fake = FakeKeystore()..install();
      expect((await _readyController(fake, _Clock(), serverOffsetS: 10)).clockSuspect, isFalse);
      expect((await _readyController(fake, _Clock(), serverOffsetS: -11)).clockSuspect, isTrue);
    });

    test('a clock that moves backwards triggers a fresh signature', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock()..now = _t0 + 100;
      final c = await _readyController(fake, clock);
      await _tick(c);

      clock.now = _t0 + 50; // user set the clock back; the old ts is now far in the future
      await _tick(c);
      expect(fake.signCount, 2);
      expect((_scan(c.qr!, clock.now) as ScanAccepted).ts, clock.now);
    });

    test('when signing fails the QR is withdrawn, then comes back by itself', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);
      await _tick(c);
      expect(c.qr, isNotNull);

      fake.failWith = PlatformException(code: 'keystore_error', message: 'busy');
      clock.now = _t0 + 30;
      await _tick(c);
      expect(c.qr, isNull, reason: 'a stale QR must not stay on screen');
      expect(c.fault, PassFault.signingFailed);

      clock.now = _t0 + 31;
      await _tick(c); // still failing: retried on every tick
      expect(c.fault, PassFault.signingFailed);

      fake.failWith = null;
      clock.now = _t0 + 32;
      await _tick(c);
      expect(c.fault, isNull);
      expect(_scan(c.qr!, clock.now), isA<ScanAccepted>());
    });

    test('when the key disappears the pass stops signing instead of creating a new key', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);
      await _tick(c);

      fake.hasKey = false;
      clock.now = _t0 + 30;
      await _tick(c);
      expect(c.qr, isNull);
      expect(c.fault, PassFault.signingFailed);
      expect(fake.hasKey, isFalse);
    });

    test('at the expiry second the QR is withdrawn and signing stops for good', () async {
      final fake = FakeKeystore()..install();
      final clock = _Clock();
      final c = await _readyController(fake, clock);
      await _tick(c);
      final exp = c.credential.exp;

      clock.now = exp - 1;
      await _tick(c);
      expect(_scan(c.qr!, clock.now), isA<ScanAccepted>());

      clock.now = exp;
      await _tick(c);
      expect(c.qr, isNull);
      expect(c.fault, PassFault.expired);

      final signs = fake.signCount;
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(fake.signCount, signs);
    });

    test('QR text is within the size the spec budgets for', () async {
      final fake = FakeKeystore()..install();
      final c = await _readyController(fake, _Clock());
      await _tick(c);
      expect(c.qr!.length, lessThanOrEqualTo(430));
      expect(_sidOf(_scan(c.qr!, _t0)), 900001);
    });
  });
}
