import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:student_app/src/app.dart';
import 'package:student_app/src/id_card.dart';
import 'package:student_app/src/keystore_signer.dart';
import 'package:student_app/src/pass_screen.dart';
import 'package:student_app/src/pass_store.dart';
import 'package:student_app/src/photo_source.dart';
import 'package:student_app/src/session_store.dart';

import 'support/fake_campus_server.dart';
import 'support/fake_keystore.dart';

const int _t0 = 1790000000;
const String _ravi = 'ravi.kumar@college.test';

/// The app, a student's fingers and a fake college, end to end through the screens.
class _World {
  _World({bool allowInsecure = true}) : _allowInsecure = allowInsecure;

  final bool _allowInsecure;
  final server = FakeCampusServer(nowS: _t0);
  final keystore = FakeKeystore(hasKey: false);
  final passes = MemoryPassStore();
  final sessions = MemorySessionStore();
  final photos = FakePhotos();
  final cards = FakeCards();
  int now = _t0;

  Widget app({Duration pollEvery = const Duration(seconds: 4)}) => StudentApp(
        store: passes,
        signer: KeystoreSigner(),
        sessions: sessions,
        photos: photos,
        cards: cards,
        apiFor: server.apiFor,
        defaultServer: Uri.parse('http://127.0.0.1:8787'),
        phoneNowS: () => now,
        allowDemo: false,
        allowInsecure: _allowInsecure,
        pollEvery: pollEvery,
      );

  Future<void> launch(WidgetTester tester) async {
    keystore.install();
    await tester.pumpWidget(app());
    await settle(tester);
  }
}

/// Lets the async chain (fake network, stores, Keystore, signing) run; periodic timers make pumpAndSettle unusable.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

/// Lets a menu or dialog finish opening or closing: an animation starts on the frame after it is asked for.
Future<void> animate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

final _email = find.byKey(const ValueKey('email-field'));
final _code = find.byKey(const ValueKey('code-field'));
final _phone = find.byKey(const ValueKey('phone-field'));

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await settle(tester);
}

Future<void> tapButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await settle(tester);
}

Future<void> signIn(WidgetTester tester, {String email = _ravi}) async {
  await tester.enterText(_email, email);
  await tapButton(tester, 'Send code');
  await tapText(tester, 'Use it');
  await tapButton(tester, 'Sign in');
}

Future<void> sendDetails(WidgetTester tester) async {
  await tapText(tester, 'Take photo');
  await tester.enterText(_phone, '+91 98765 43210');
  await settle(tester);
  await tapButton(tester, 'Send for approval');
}

String _qrData(WidgetTester tester) => tester.widget<PassScreen>(find.byType(PassScreen)).controller.qr!;

late WidgetTester tester0;

void main() {
  testWidgets('a new student: sign in, details, waiting, then a pass that a scanner accepts', (tester) async {
    final w = _World();
    await w.launch(tester);

    // Sign in with the college email and the code shown in demo mode.
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await tester.enterText(_email, 'Ravi.Kumar@College.test');
    await tapButton(tester, 'Send code');
    expect(find.text('We sent a 6-digit code to $_ravi.'), findsOneWidget);
    expect(find.textContaining('Demo mode: no email is sent'), findsOneWidget);
    expect(find.textContaining('123456', findRichText: true), findsOneWidget);
    await tapText(tester, 'Use it');
    await tapButton(tester, 'Sign in');

    // The details page knows who this is, and wants a photo and a number before it lets go.
    expect(find.text('One more step'), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('25071A0003 · CSE · Year 1'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send for approval')).onPressed, isNull);
    await tapText(tester, 'Take photo');
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    expect(w.photos.asked, [PhotoOrigin.camera]);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send for approval')).onPressed, isNull, reason: 'still no phone number');
    await tester.enterText(_phone, '+91 98765 43210');
    await settle(tester);
    await tapButton(tester, 'Send for approval');

    // Waiting. Nothing happens until the college approves; then the page notices by itself.
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(w.server.phones[_ravi], '+919876543210');
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(find.text('Waiting for approval'), findsOneWidget);

    w.server.approve(_ravi);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);

    // The pass: bound to this phone's key, accepted by a scanner that trusts the college key.
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('25071A0003 · CSE · Year 1'), findsOneWidget);
    final qr = _qrData(tester);
    final scan = verifyScan(qr, now: w.now, keys: {1: collegePublicKv1});
    expect(scan, isA<ScanAccepted>());
    expect((scan as ScanAccepted).credential.name, 'Ravi Kumar');
    expect(scan.credential.dpk, w.keystore.publicKey);

    await unmount(tester);
  });

  testWidgets('the same pass is there after the app is closed and opened again, with no network', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);
    await sendDetails(tester);
    w.server.approve(_ravi);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    await unmount(tester);

    w.server.offline = true;
    await tester.pumpWidget(w.app());
    await settle(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an email that is not on the roster says so and stays on the page', (tester) async {
    final w = _World();
    await w.launch(tester);
    await tester.enterText(_email, 'stranger@college.test');
    await tapButton(tester, 'Send code');

    expect(find.textContaining('@vnrvjiet.in'), findsWidgets);
    expect(_email, findsOneWidget);
    expect(_code, findsNothing);
  });

  testWidgets('a wrong code says so and keeps the code box; "use a different email" goes back', (tester) async {
    final w = _World();
    await w.launch(tester);
    await tester.enterText(_email, _ravi);
    await tapButton(tester, 'Send code');
    await tester.enterText(_code, '999999');
    await tapButton(tester, 'Sign in');

    expect(find.textContaining('wrong or has expired'), findsOneWidget);
    expect(_code, findsOneWidget);

    await tapText(tester, 'Use a different email');
    expect(_email, findsOneWidget);
    expect(find.textContaining('wrong or has expired'), findsNothing);
  });

  testWidgets('the code box takes digits only and at most six', (tester) async {
    final w = _World();
    await w.launch(tester);
    await tester.enterText(_email, _ravi);
    await tapButton(tester, 'Send code');
    await tester.enterText(_code, '12ab34-56789');
    await settle(tester);

    expect(tester.widget<TextField>(_code).controller!.text, '123456');
  });

  testWidgets('the details page keeps the button off until there is a usable phone number and a photo', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);

    bool enabled() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send for approval')).onPressed != null;

    await tester.enterText(_phone, '12345');
    await settle(tester);
    await tapText(tester, 'Take photo');
    expect(enabled(), isFalse, reason: 'a photo, but the number is too short');

    await tester.enterText(_phone, '98765 43210');
    await settle(tester);
    expect(enabled(), isTrue);
  });

  testWidgets('the gallery works as well as the camera, and backing out of the picker changes nothing', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);

    w.photos.photo = null;
    await tapText(tester, 'Take photo');
    expect(find.byKey(const ValueKey('photo-preview')), findsNothing);

    w.photos.photo = testPhoto();
    await tapText(tester, 'Choose from gallery');
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    expect(w.photos.asked, [PhotoOrigin.camera, PhotoOrigin.gallery]);
    expect(find.text('Retake'), findsOneWidget);
  });

  testWidgets('a camera that will not open says what to do instead', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);

    w.photos.failWith = const PhotoException('camera_access_denied');
    await tapText(tester, 'Take photo');

    expect(find.textContaining('Allow the camera for this app, or choose one from the gallery'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
  });

  testWidgets('a rejected photo comes back to the details page with the reason, and can be replaced', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);
    await sendDetails(tester);

    w.server.reject(_ravi);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);

    expect(find.text('One more step'), findsOneWidget);
    expect(find.textContaining('did not accept your photo'), findsOneWidget);

    await sendDetails(tester);
    expect(find.text('Waiting for approval'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the waiting page says quietly when the server cannot be reached, and recovers', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);
    await sendDetails(tester);

    w.server.offline = true;
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.textContaining("Can't reach the college server right now"), findsOneWidget);

    w.server.offline = false;
    await tapText(tester, 'Check now');
    expect(find.textContaining("Can't reach the college server right now"), findsNothing);
    await unmount(tester);
  });

  testWidgets('a college that cannot be reached at start offers "Try again"', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);
    await unmount(tester);

    w.server.offline = true;
    await tester.pumpWidget(w.app());
    await settle(tester);
    expect(find.text("Couldn't get your pass"), findsOneWidget);
    expect(find.textContaining("Can't reach the college server"), findsOneWidget);

    w.server.offline = false;
    await tapButton(tester, 'Try again');
    expect(find.text('One more step'), findsOneWidget);
  });

  testWidgets('signing out from the pass asks first, then returns to sign-in and empties the phone', (tester) async {
    final w = _World();
    await w.launch(tester);
    await signIn(tester);
    await sendDetails(tester);
    w.server.approve(_ravi);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(find.byType(QrImageView), findsOneWidget);

    Future<void> openMenuAndChooseSignOut() async {
      await tester.tap(find.byTooltip('Menu'));
      await animate(tester);
      await tester.tap(find.text('Sign out'));
      await animate(tester);
    }

    await openMenuAndChooseSignOut();
    expect(find.text('Sign out?'), findsOneWidget);

    // Cancel changes nothing.
    await tester.tap(find.text('Cancel'));
    await animate(tester);
    expect(find.text('Sign out?'), findsNothing);
    expect(find.byType(QrImageView), findsOneWidget);

    await openMenuAndChooseSignOut();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await settle(tester);
    await animate(tester);

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(await w.passes.load(), isNull);
    expect(await w.sessions.load(), isNull);
    expect(w.keystore.hasKey, isFalse);
    await unmount(tester);
  });

  testWidgets('the server address can be changed on the sign-in page, and a bad one is refused', (tester) async {
    final w = _World();
    await w.launch(tester);

    expect(find.text('http://127.0.0.1:8787'), findsOneWidget);
    await tapText(tester, 'Change');
    await tester.enterText(find.byKey(const ValueKey('server-field')), 'not a server');
    await tapText(tester, 'Use this server');
    expect(find.text("That doesn't look like a server address."), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('server-field')), '192.168.1.20:8787');
    await tapText(tester, 'Use this server');
    expect(find.text('http://192.168.1.20:8787'), findsOneWidget);
    expect(await w.sessions.loadServer(), 'http://192.168.1.20:8787');
  });

  testWidgets('with no server configured the page asks for one before anything else', (tester) async {
    final w = _World();
    w.keystore.install();
    await tester.pumpWidget(StudentApp(store: w.passes, signer: KeystoreSigner(), sessions: w.sessions, photos: w.photos, apiFor: w.server.apiFor, allowDemo: false));
    await settle(tester);

    expect(find.byKey(const ValueKey('server-field')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send code')).onPressed, isNull);
  });

  group('a student the roster does not list', () {
    const mine = '25071a66j1@vnrvjiet.in';
    final nameField = find.byKey(const ValueKey('name-field'));
    final branchField = find.byKey(const ValueKey('branch-field'));

    String textOf(Finder f) => tester0.widget<TextField>(f).controller!.text;

    testWidgets('scans the ID card, checks what it read, and gets the pass at once', (tester) async {
      tester0 = tester;
      final w = _World();
      w.server.autoApprove = true;
      w.cards.card = const CardDetails(rollNumber: '25071A66J1', name: 'Test Student', branch: 'CSE-DS', year: 2);
      await w.launch(tester);
      await signIn(tester, email: mine);

      expect(find.text('Scan your college ID card'), findsOneWidget);
      expect(find.text('25071A66J1'), findsWidgets, reason: 'the page knows only the roll number so far');
      expect(textOf(nameField), '');
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Get my pass')).onPressed, isNull);

      await tapText(tester, 'Scan ID card');
      expect(w.cards.asked, [PhotoOrigin.camera]);
      expect(textOf(nameField), 'Test Student');
      expect(textOf(branchField), 'CSE-DS');
      expect(find.textContaining('Read from your card (25071A66J1)'), findsOneWidget);

      await tapText(tester, 'Take photo');
      await tester.enterText(_phone, '+91 98765 43210');
      await settle(tester);
      await tapButton(tester, 'Get my pass');

      expect(find.byType(QrImageView), findsOneWidget, reason: 'no waiting for an admin');
      expect(w.server.lastProfile, {'name': 'Test Student', 'branch': 'CSE-DS', 'year': 2});
      final scan = verifyScan(_qrData(tester), now: w.now, keys: {1: collegePublicKv1}) as ScanAccepted;
      expect(scan.credential.name, 'Test Student');
      expect(scan.credential.roll, '25071A66J1');
      await unmount(tester);
    });

    testWidgets('what the card got wrong can be corrected before sending', (tester) async {
      tester0 = tester;
      final w = _World();
      w.server.autoApprove = true;
      w.cards.card = const CardDetails(rollNumber: '25071A66J1', name: 'Tesst Studnt', branch: 'CSE', year: 2);
      await w.launch(tester);
      await signIn(tester, email: mine);
      await tapText(tester, 'Scan ID card');
      await tester.enterText(nameField, 'Test Student');
      await tester.enterText(branchField, 'cse-ds');
      await tapText(tester, 'Take photo');
      await tester.enterText(_phone, '9876543210');
      await settle(tester);
      await tapButton(tester, 'Get my pass');

      expect(w.server.lastProfile, {'name': 'Test Student', 'branch': 'CSE-DS', 'year': 2}, reason: 'the branch is sent in capitals');
      await unmount(tester);
    });

    testWidgets("someone else's card is refused and nothing from it is used", (tester) async {
      tester0 = tester;
      final w = _World();
      w.cards.card = const CardDetails(rollNumber: '25071A0002', name: 'Anita Rao', branch: 'ECE', year: 3);
      await w.launch(tester);
      await signIn(tester, email: mine);
      await tapText(tester, 'Scan ID card');

      expect(find.textContaining('This card is for 25071A0002, but you signed in as 25071A66J1'), findsOneWidget);
      expect(textOf(nameField), '', reason: 'nothing from the other student is filled in');
      await tapText(tester, 'Take photo');
      await tester.enterText(nameField, 'Test Student');
      await tester.enterText(branchField, 'CSE-DS');
      await tester.enterText(_phone, '9876543210');
      await settle(tester);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Get my pass')).onPressed, isNull, reason: 'cannot go on while the wrong card is the last one scanned');

      w.cards.card = const CardDetails(rollNumber: '25071A66J1', name: 'Test Student', branch: 'CSE-DS', year: 2);
      await tapText(tester, 'Scan again');
      expect(find.textContaining('This card is for'), findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Get my pass')).onPressed, isNotNull);
    });

    testWidgets('a card that could not be read says so and the details can be typed', (tester) async {
      tester0 = tester;
      final w = _World();
      w.cards.card = const CardDetails(text: 'blur');
      await w.launch(tester);
      await signIn(tester, email: mine);
      await tapText(tester, 'Scan ID card');

      expect(find.textContaining("Couldn't read much from the card"), findsOneWidget);
      await tester.enterText(nameField, 'Test Student');
      await tester.enterText(branchField, 'CSE-DS');
      await tapText(tester, 'Take photo');
      await tester.enterText(_phone, '9876543210');
      await settle(tester);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Get my pass')).onPressed, isNotNull);
    });

    testWidgets('a camera that will not open says what to do', (tester) async {
      tester0 = tester;
      final w = _World();
      w.cards.failWith = const PhotoException('camera_access_denied');
      await w.launch(tester);
      await signIn(tester, email: mine);
      await tapText(tester, 'Scan ID card');

      expect(find.textContaining("Couldn't read the card"), findsOneWidget);
      expect(find.textContaining('choose a photo from the gallery'), findsOneWidget);
    });

    testWidgets('the year is already filled from the roll number, before any scan', (tester) async {
      tester0 = tester;
      final w = _World();
      await w.launch(tester);
      await signIn(tester, email: mine);
      final year = tester.widget<DropdownButtonFormField<int>>(find.byKey(const ValueKey('year-field')));
      expect(year.initialValue, yearOfStudy(2025, DateTime.now()));
    });

    testWidgets('a student the roster lists sees no card section', (tester) async {
      tester0 = tester;
      final w = _World();
      await w.launch(tester);
      await signIn(tester);
      expect(find.text('Scan your college ID card'), findsNothing);
      expect(find.text('One more step'), findsOneWidget);
    });
  });

  group('on a small phone with large text nothing overflows', () {
    Future<void> small(WidgetTester tester) async {
      tester.view.physicalSize = const Size(960, 1707); // 320 x 569 dp at 3x
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
    }

    testWidgets('sign-in, code, details and waiting pages', (tester) async {
      await small(tester);
      final w = _World();
      await w.launch(tester);
      expect(tester.takeException(), isNull);

      await tester.enterText(_email, _ravi);
      await tapButton(tester, 'Send code');
      expect(tester.takeException(), isNull);

      await tapText(tester, 'Use it');
      await tapButton(tester, 'Sign in');
      expect(tester.takeException(), isNull);

      await sendDetails(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Waiting for approval'), findsOneWidget);
      await unmount(tester);
    });
  });

  testWidgets('dark theme: the pages build and the text stays readable', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final w = _World();
    await w.launch(tester);
    await tester.enterText(_email, _ravi);
    await tapButton(tester, 'Send code');

    expect(tester.takeException(), isNull);
    expect(Theme.of(tester.element(find.text('Sign in').first)).brightness, Brightness.dark);
  });
}
