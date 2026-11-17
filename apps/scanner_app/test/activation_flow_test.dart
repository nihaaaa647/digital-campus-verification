import 'dart:async';
import 'dart:io';

import 'package:campus_ui/campus_ui.dart';
import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/activation_screen.dart';
import 'package:scanner_app/src/app.dart';
import 'package:scanner_app/src/key_set.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/scanner_identity.dart';
import 'package:scanner_app/src/sync_client.dart';

import 'support/disk_bundle.dart';
import 'support/fake_backend.dart';
import 'support/vectors.dart';

/// The scanner starts in verify mode, which records nothing. Tests that look at recorded exits switch to out pass
/// mode first, as a guard does.
Future<void> outPassMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mode-outpass')));
  await tester.pump();
}

void main() {
  final vec = Vectors.load();
  late void Function(String) feed;

  Widget fakeCamera(BuildContext context, void Function(String) onCode) {
    feed = onCode;
    return const ColoredBox(color: Colors.black54);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  group('the code field', () {
    String format(String typed) => const ActivationCodeFormatter().formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: typed)).text;

    test('puts a hyphen after the fourth character and capitalises', () {
      expect(format('k7qm'), 'K7QM');
      expect(format('k7qm2'), 'K7QM-2');
      expect(format('k7qm29xd'), 'K7QM-29XD');
    });

    test('ignores everything that is not a letter or digit, and stops at eight', () {
      expect(format('K7QM-29XD'), 'K7QM-29XD');
      expect(format(' k7 qm_29-xd!! '), 'K7QM-29XD');
      expect(format('K7QM29XDEXTRA'), 'K7QM-29XD');
      expect(format('---'), '');
    });
  });

  group('the activation screen', () {
    Future<List<(String, String)>> pump(WidgetTester tester, {Future<String?> Function(String, String)? onSubmit, VoidCallback? onCancel, String server = ''}) async {
      final calls = <(String, String)>[];
      await tester.pumpWidget(MaterialApp(
        theme: CampusTheme.dark(),
        home: ActivationScreen(
          initialServer: server,
          onCancel: onCancel,
          onSubmit: (s, c) {
            calls.add((s, c));
            return onSubmit?.call(s, c) ?? Future.value(null);
          },
        ),
      ));
      return calls;
    }

    Finder serverField() => find.byType(TextField).at(0);
    Finder codeField() => find.byType(TextField).at(1);
    FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton));

    testWidgets('asks for a server address and a code, and cannot be pressed until both are filled', (tester) async {
      await pump(tester);

      expect(find.text('Activate this scanner'), findsOneWidget);
      expect(find.text('Server address'), findsOneWidget);
      expect(find.text('Activation code'), findsOneWidget);
      expect(button(tester).onPressed, isNull);

      await tester.enterText(serverField(), 'xyz.supabase.co');
      await tester.pump();
      expect(button(tester).onPressed, isNull, reason: 'still no code');

      await tester.enterText(codeField(), 'k7qm29');
      await tester.pump();
      expect(button(tester).onPressed, isNull, reason: 'a code is eight characters');

      await tester.enterText(codeField(), 'k7qm29xd');
      await tester.pump();
      expect(button(tester).onPressed, isNotNull);
      expect(find.text('K7QM-29XD'), findsOneWidget, reason: 'the field tidied what was typed');
    });

    testWidgets('starts with the address it is given', (tester) async {
      await pump(tester, server: 'https://xyz.supabase.co');
      expect(find.text('https://xyz.supabase.co'), findsOneWidget);
    });

    testWidgets('sends what was typed', (tester) async {
      final calls = await pump(tester);
      await tester.enterText(serverField(), '  xyz.supabase.co ');
      await tester.enterText(codeField(), 'k7qm29xd');
      await tester.pump();

      await tester.tap(find.text('Activate scanner'));
      await tester.pump();

      expect(calls, [('xyz.supabase.co', 'K7QM-29XD')]);
    });

    testWidgets('shows what went wrong, in words, and lets the guard try again', (tester) async {
      await pump(tester, onSubmit: (a, b) async => "That code isn't valid or has expired.");
      await tester.enterText(serverField(), 'xyz.supabase.co');
      await tester.enterText(codeField(), 'k7qm29xd');
      await tester.pump();

      await tester.tap(find.text('Activate scanner'));
      await tester.pump();
      await tester.pump();

      expect(find.text("That code isn't valid or has expired."), findsOneWidget);
      expect(button(tester).onPressed, isNotNull, reason: 'it can be pressed again');
    });

    testWidgets('while it works it shows progress and cannot be pressed twice', (tester) async {
      final done = Completer<String?>();
      final calls = await pump(tester, onSubmit: (a, b) => done.future);
      await tester.enterText(serverField(), 'xyz.supabase.co');
      await tester.enterText(codeField(), 'k7qm29xd');
      await tester.pump();

      await tester.tap(find.text('Activate scanner'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(button(tester).onPressed, isNull);
      expect(calls, hasLength(1));

      done.complete('x');
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an unexpected error becomes a message, not a crash', (tester) async {
      await pump(tester, onSubmit: (a, b) async => throw StateError('boom'));
      await tester.enterText(serverField(), 'xyz.supabase.co');
      await tester.enterText(codeField(), 'k7qm29xd');
      await tester.pump();

      await tester.tap(find.text('Activate scanner'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    });

    testWidgets('"Not now" appears only when the scanner can go back to scanning', (tester) async {
      await pump(tester);
      expect(find.text('Not now'), findsNothing);

      var cancelled = false;
      await pump(tester, onCancel: () => cancelled = true);
      await tester.tap(find.text('Not now'));
      expect(cancelled, isTrue);
    });
  });

  group('the whole app', () {
    late FakeBackend backend;
    late SqliteScanLog log; // the test's own connection, for setting up and checking
    late MemoryIdentityStore identities;
    late Directory dir;

    // The app opens (and closes) its own connection on every launch, as it does on a phone.
    Future<SqliteScanLog> openLog() async => SqliteScanLog.open('${dir.path}/scan_log.db');

    setUp(() {
      backend = FakeBackend(vec);
      identities = MemoryIdentityStore();
      dir = Directory.systemTemp.createTempSync('activation_flow');
      log = SqliteScanLog.open('${dir.path}/scan_log.db');
    });
    tearDown(() async {
      await log.close();
      dir.deleteSync(recursive: true);
    });

    Future<void> launch(WidgetTester tester, {bool devKeys = false, SyncConfig? syncConfig, String defaultServer = ''}) async {
      await tester.pumpWidget(ScannerApp(
        keySetSource: devKeys ? AssetKeySet(devKeySetAsset, bundle: DiskBundle()) : null,
        cameraBuilder: fakeCamera,
        openLog: openLog,
        identityStore: identities,
        syncConfig: syncConfig,
        defaultServer: defaultServer,
        allowInsecure: true,
        httpClient: backend.client,
        phoneNowS: () => vec.referenceNow,
      ));
      await settle(tester);
    }

    Future<void> typeAndActivate(WidgetTester tester, {String server = 'https://xyz.supabase.co', String code = 'K7QM-29XD'}) async {
      await tester.enterText(find.byType(TextField).at(0), server);
      await tester.enterText(find.byType(TextField).at(1), code);
      await tester.pump();
      await tester.tap(find.text('Activate scanner'));
      await settle(tester);
    }

    Future<void> scanDemoPass(WidgetTester tester) async {
      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('a new scanner with no keys can do nothing but activate', (tester) async {
      await launch(tester);

      expect(find.text('Activate this scanner'), findsOneWidget);
      expect(find.textContaining('no college keys yet'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);
      expect(find.text("Point at the student's QR code"), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('activating gives it keys, its gate and its token, and it goes straight to scanning', (tester) async {
      await launch(tester, defaultServer: 'https://xyz.supabase.co');
      expect(find.text('https://xyz.supabase.co'), findsOneWidget, reason: 'the build\'s default server address is prefilled');

      await typeAndActivate(tester, code: 'k7qm29xd');

      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(find.text('DEV KEYS'), findsNothing, reason: 'these keys came from the server');
      expect((await identities.load())!.token, backend.token);
      expect(await log.storedKeySet(), backend.keySet);

      await scanDemoPass(tester);
      expect(find.text('VALID PASS'), findsOneWidget);
      expect((await log.oldest(1)).single.gate, 'North gate', reason: 'the gate the server named, not a placeholder');

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(backend.syncHeaders.last['Authorization'], 'Bearer ${backend.token}', reason: 'it syncs as itself');
      expect(backend.syncUrls.last.toString(), 'https://xyz.supabase.co/functions/v1/scanner-sync');
      expect(await log.count(), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a wrong code is explained and nothing changes', (tester) async {
      await launch(tester);
      await typeAndActivate(tester, code: 'ZZZZ-ZZZZ');

      expect(find.textContaining("isn't valid or has expired"), findsOneWidget);
      expect(find.text('Activate this scanner'), findsOneWidget);
      expect(await identities.load(), isNull);
      expect(await log.storedKeySet(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after a restart it remembers: no activation, and it syncs with the saved token', (tester) async {
      await launch(tester);
      await typeAndActivate(tester);
      await tester.pumpWidget(const SizedBox()); // the app is closed

      await launch(tester);

      expect(find.text('Activate this scanner'), findsNothing);
      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(backend.activations, hasLength(1), reason: 'it did not ask the server again');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(backend.syncHeaders.last['Authorization'], 'Bearer ${backend.token}');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a development build without activation shows DEV KEYS and offers to activate', (tester) async {
      await launch(tester, devKeys: true);

      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(find.text('DEV KEYS'), findsOneWidget);
      expect(find.text('Activate'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Activate" opens the form, "Not now" returns to scanning', (tester) async {
      await launch(tester, devKeys: true);

      await tester.tap(find.text('Activate'));
      await settle(tester);
      expect(find.text('Activate this scanner'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await settle(tester);
      expect(find.text("Point at the student's QR code"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('activating from a development build replaces the test keys with the server\'s', (tester) async {
      await launch(tester, devKeys: true);
      expect(find.text('DEV KEYS'), findsOneWidget);

      await tester.tap(find.text('Activate'));
      await settle(tester);
      await typeAndActivate(tester);

      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(find.text('DEV KEYS'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the server\'s keys win over the test keys: a pass signed by a key the server does not list is refused', (tester) async {
      // The server lists only key version 9; the test key set (versions 1 and 2) is also bundled.
      await log.saveKeySet({
        'v': 1,
        'current': 9,
        'keys': [
          {'kv': 9, 'alg': 'ES256', 'pub': toBase64Url(vec.collegePublic[3]!)},
        ],
      });
      await launch(tester, devKeys: true);

      expect(find.text('DEV KEYS'), findsNothing);
      await scanDemoPass(tester);

      expect(find.text('NOT VALID'), findsOneWidget);
      expect(find.text('Unknown ID'), findsOneWidget);
      expect(await log.count(), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a damaged saved key set is ignored: the scanner falls back, it does not crash', (tester) async {
      await log.saveKeySet({'v': 99});
      await launch(tester, devKeys: true);

      expect(find.text('DEV KEYS'), findsOneWidget);
      expect(find.text("Point at the student's QR code"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a token the server no longer accepts shows "Not authorised", and tapping it opens activation', (tester) async {
      await identities.save(ScannerIdentity(serverBase: Uri.parse('https://xyz.supabase.co'), scannerId: 'SC-NEW', name: 'x', gate: 'North gate', token: 'an-old-token-${'Z' * 30}'));
      await log.saveKeySet(backend.keySet!);
      await launch(tester);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Not authorised'), findsOneWidget);

      await tester.tap(find.text('Not authorised'));
      await settle(tester);
      expect(find.text('Activate this scanner'), findsOneWidget);
      expect(find.text('https://xyz.supabase.co'), findsOneWidget, reason: 'the address it already knows is filled in');

      backend.validCodes.add('NEWCADEA');
      await typeAndActivate(tester, server: 'https://xyz.supabase.co', code: 'NEWC-ADEA');
      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect((await identities.load())!.token, backend.token, reason: 'the new token replaced the refused one');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a build with a fixed development token does not ask to be activated', (tester) async {
      await launch(tester, devKeys: true, syncConfig: SyncConfig(endpoint: Uri.parse('https://xyz.supabase.co/functions/v1/scanner-sync'), token: backend.token));

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(find.text('Activate'), findsNothing);
      expect(find.textContaining('Synced'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('if the encrypted storage cannot be read the scanner behaves as not activated', (tester) async {
      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        cameraBuilder: fakeCamera,
        openLog: openLog,
        identityStore: _UnreadableIdentityStore(),
        httpClient: backend.client,
        phoneNowS: () => vec.referenceNow,
      ));
      await settle(tester);

      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(find.text('Activate'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _UnreadableIdentityStore implements IdentityStore {
  @override
  Future<ScannerIdentity?> load() async => throw StateError('keystore key was wiped');

  @override
  Future<void> save(ScannerIdentity identity) async {}

  @override
  Future<void> clear() async {}
}
