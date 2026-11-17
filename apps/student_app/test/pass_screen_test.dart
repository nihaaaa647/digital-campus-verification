import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:student_app/src/app.dart';
import 'package:student_app/src/demo_issuer.dart';
import 'package:student_app/src/keystore_signer.dart';
import 'package:student_app/src/pass_screen.dart';
import 'package:student_app/src/pass_store.dart';
import 'package:student_app/src/session_store.dart';

import 'support/fake_campus_server.dart';
import 'support/fake_keystore.dart';

const int _t0 = 1790000000;

class _Clock {
  int now = _t0;
  int call() => now;
}

/// Lets the async chain (store, channel, signing) run; periodic timers make pumpAndSettle unusable.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

/// The text the screen is drawing as a QR code (QrImageView keeps its data private).
String _qrData(WidgetTester tester) => tester.widget<PassScreen>(find.byType(PassScreen)).controller.qr!;

ScanOutcome _scan(String qr, int now) => verifyScan(qr, now: now, keys: {1: collegePublicKv1});

Future<_Clock> _pumpApp(WidgetTester tester, FakeKeystore fake, MemoryPassStore store) async {
  fake.install();
  final clock = _Clock();
  await tester.pumpWidget(_app(store, phoneNowS: clock.call));
  await _settle(tester);
  return clock;
}

/// The app on fakes: no network (every call would fail as offline), no camera.
StudentApp _app(PassStore store, {int Function()? phoneNowS, bool allowDemo = true}) {
  final server = FakeCampusServer()..offline = true;
  return StudentApp(
    store: store,
    signer: KeystoreSigner(),
    sessions: MemorySessionStore(),
    photos: FakePhotos(),
    apiFor: server.apiFor,
    defaultServer: Uri.parse('http://127.0.0.1:8787'),
    phoneNowS: phoneNowS,
    allowDemo: allowDemo,
  );
}

/// Removing the screen disposes the controller, which cancels its timer.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('no pass stored: asks to sign in, and the debug build offers a demo pass', (tester) async {
    await _pumpApp(tester, FakeKeystore(hasKey: false), MemoryPassStore());

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Create demo pass (debug build)'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('release behaviour: no demo button when allowDemo is off', (tester) async {
    FakeKeystore(hasKey: false).install();
    await tester.pumpWidget(_app(MemoryPassStore(), allowDemo: false));
    await _settle(tester);

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.textContaining('demo', findRichText: true), findsNothing);
  });

  testWidgets('shows identity and a QR that a scanner accepts, then renews it every 30 s', (tester) async {
    final fake = FakeKeystore(hasKey: false);
    final clock = await _pumpApp(tester, fake, MemoryPassStore());

    await tester.tap(find.text('Create demo pass (debug build)'));
    await _settle(tester);

    expect(fake.hasKey, isTrue, reason: 'enrolling creates the device key');
    expect(find.text('Demo Student'), findsOneWidget);
    expect(find.text('DEMO0001 · CSE · Year 3'), findsOneWidget);
    expect(find.text('Student'), findsOneWidget);
    expect(find.text('New code in 30 s'), findsOneWidget);

    final first = _qrData(tester);
    expect(_scan(first, clock.now), isA<ScanAccepted>());
    expect(tester.widget<QrImageView>(find.byType(QrImageView)).errorCorrectionLevel, QrErrorCorrectLevel.L);

    // 29 seconds on: same code, one second left.
    for (var s = 1; s <= 29; s++) {
      clock.now = _t0 + s;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(_qrData(tester), first);
    expect(find.text('New code in 1 s'), findsOneWidget);

    // The 30th second: a new signature with a new timestamp.
    clock.now = _t0 + 30;
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    final second = _qrData(tester);
    expect(second, isNot(first));
    final accepted = _scan(second, clock.now) as ScanAccepted;
    expect(accepted.ts, _t0 + 30);
    expect(accepted.credential.name, 'Demo Student');
    expect(find.text('New code in 30 s'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('the pass survives a restart: reopening the app shows it without the demo button', (tester) async {
    final fake = FakeKeystore();
    final store = MemoryPassStore(issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0));
    await _pumpApp(tester, fake, store);

    expect(find.text('Demo Student'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Create demo pass (debug build)'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('withdraws the QR and explains when the pass expires while the screen is open', (tester) async {
    final fake = FakeKeystore();
    final store = MemoryPassStore(issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0));
    final clock = await _pumpApp(tester, fake, store);
    expect(find.byType(QrImageView), findsOneWidget);

    clock.now = _t0 + 30 * 24 * 60 * 60; // exactly exp
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Pass expired'), findsOneWidget);
    expect(find.text('Connect to the internet to renew it.'), findsOneWidget);
    expect(find.textContaining('New code in'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('warns about a phone clock more than 10 s from the server', (tester) async {
    final fake = FakeKeystore();
    final pass = issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0);
    final store = MemoryPassStore(StoredPass(signedCredential: pass.signedCredential, serverOffsetS: -25));
    await _pumpApp(tester, fake, store);

    expect(find.textContaining("clock is 25 s ahead of the college server"), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('on a small phone with large text the QR stays big and nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(960, 1707); // 320 x 569 dp at 3x
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final fake = FakeKeystore();
    await _pumpApp(tester, fake, MemoryPassStore(issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0)));

    // 320 dp minus 16 dp page padding, 12 dp card padding and 14 dp quiet zone on each side is 236 dp:
    // about 3.6 dp per module for a version 12 code, which is 11 physical pixels at 3x.
    expect(tester.getSize(find.byType(QrImageView)).width, greaterThanOrEqualTo(224));
    expect(tester.takeException(), isNull);

    await _unmount(tester);
  });

  testWidgets('a pass for a different device key asks the student to register this phone again', (tester) async {
    final fake = FakeKeystore(privateKey: devBPrivate);
    final store = MemoryPassStore(issueDemoPass(devicePublicKey: publicKeyOf(devAPrivate), nowS: _t0));
    await _pumpApp(tester, fake, store);

    expect(find.textContaining("security key is not the one your pass was issued to"), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Reset this phone (debug build)'), findsOneWidget);
  });

  test('the QR the demo pass produces fits QR version 12 at level L, as the spec budgets', () async {
    final fake = FakeKeystore();
    TestWidgetsFlutterBinding.ensureInitialized();
    fake.install();
    final pass = issueDemoPass(devicePublicKey: fake.publicKey, nowS: _t0);
    final signed = parseSignedCredential(pass.signedCredential)!;
    final qr = await buildScanQr(signed, _t0, KeystoreSigner());

    final code = QrCode.fromData(data: qr, errorCorrectLevel: QrErrorCorrectLevel.L);
    expect(qr.length, inInclusiveRange(300, 347));
    expect(code.typeNumber, lessThanOrEqualTo(12));
  });
}
