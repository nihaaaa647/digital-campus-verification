import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/app.dart';
import 'package:scanner_app/src/gate_controller.dart';
import 'package:scanner_app/src/gate_result.dart';
import 'package:scanner_app/src/key_set.dart';
import 'package:scanner_app/src/result_overlay.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/scanner_identity.dart';
import 'package:scanner_app/src/scan_screen.dart';

import 'support/disk_bundle.dart';
import 'support/vectors.dart';

/// The scanner starts in verify mode, which records nothing. Tests that look at recorded exits switch to out pass
/// mode first, as a guard does.
Future<void> outPassMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mode-outpass')));
  await tester.pump();
}

void main() {
  final vec = Vectors.load();
  late void Function(String) feed; // what the fake camera "reads"

  Widget fakeCamera(BuildContext context, void Function(String) onCode) {
    feed = onCode;
    return const ColoredBox(color: Colors.black54);
  }

  /// ScannerApp loads its keys from the asset bundle and opens the log before it shows anything; that is real
  /// I/O, which fake-async pumps alone do not wait for.
  Future<void> settleApp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  final savedTime = find.byWidgetPredicate((w) => w is Text && RegExp(r'^Saved \d\d:\d\d:\d\d$').hasMatch(w.data ?? ''));

  /// The colour the result screen is painted: its own Material, not the Scaffold's.
  Color overlayColor(WidgetTester tester) =>
      tester.widget<Material>(find.descendant(of: find.byType(ResultOverlay), matching: find.byType(Material)).first).color!;

  Map<String, dynamic> vectorCase(String id) => (vec.verifyCases.firstWhere((c) => c['id'] == id)) as Map<String, dynamic>;

  /// Shows the scan screen with the scanner clock set to what [vectorId] says its `now` is.
  Future<void> pumpScreen(WidgetTester tester, {bool devKeys = false, String vectorId = 'ok_basic', ScanLog? log, GateMode mode = GateMode.outPass}) async {
    final now = vectorCase(vectorId)['now'] as int;
    final gate = GateController(mode: mode, keys: vec.keysFor([1, 2]), log: log ?? SqliteScanLog.inMemory(), phoneNowS: () => now);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(controller: gate, cameraBuilder: fakeCamera, devKeys: devKeys)));
  }

  testWidgets('waiting: the framing guide and no result', (tester) async {
    await pumpScreen(tester, mode: GateMode.verify);

    expect(find.text("Point at the student's QR code"), findsOneWidget);
    expect(find.text('VALID PASS'), findsNothing);
    expect(find.text('NOT VALID'), findsNothing);
  });

  testWidgets('a valid pass turns the screen green with the student, then returns to scanning', (tester) async {
    await pumpScreen(tester);

    feed(vectorCase('ok_basic')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('VALID PASS'), findsOneWidget);
    expect(find.text('Sample Student'), findsOneWidget);
    expect(find.text('25071A0001'), findsOneWidget);
    expect(find.text('CSE-AIML'), findsOneWidget);
    expect(find.text('Student'), findsOneWidget);
    expect(savedTime, findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(overlayColor(tester), CampusColors.light.success);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('VALID PASS'), findsNothing);
    expect(find.text('Out pass mode · each scan is recorded'), findsOneWidget);
  });

  testWidgets('a multi-byte name is shown intact', (tester) async {
    await pumpScreen(tester);

    feed(vectorCase('ok_fresher_utf8')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Śrāvya Ñandini'), findsOneWidget);
    expect(find.text('Fresher'), findsOneWidget);
  });

  testWidgets('an expired pass turns the screen red with the reason and the next step', (tester) async {
    await pumpScreen(tester, vectorId: 'expired');

    feed(vectorCase('expired')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('NOT VALID'), findsOneWidget);
    expect(find.text('Expired pass'), findsOneWidget);
    expect(find.textContaining('open the app online to refresh'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(overlayColor(tester), CampusColors.light.danger);
  });

  testWidgets('something that is not a campus pass at all is red, never green', (tester) async {
    await pumpScreen(tester);

    feed('https://example.com/not-a-pass');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('NOT VALID'), findsOneWidget);
    expect(find.text('Bad signature'), findsOneWidget);
    expect(find.text('VALID PASS'), findsNothing);
  });

  testWidgets('tapping the result goes straight back to scanning', (tester) async {
    await pumpScreen(tester);
    feed(vectorCase('ok_basic')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('VALID PASS'), findsOneWidget);

    await tester.tap(find.text('Tap to scan the next pass'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('VALID PASS'), findsNothing);
  });

  testWidgets('the dev-keys banner shows only when the scanner trusts test keys', (tester) async {
    await pumpScreen(tester, devKeys: true);
    expect(find.text('DEV KEYS'), findsOneWidget);

    await pumpScreen(tester);
    expect(find.text('DEV KEYS'), findsNothing);
  });

  testWidgets('on a small phone with large text the longest red screen still fits or scrolls', (tester) async {
    tester.view.physicalSize = const Size(960, 1707); // 320 x 569 dp at 3x
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pumpScreen(tester, vectorId: 'clock_age_46s');

    feed(vectorCase('clock_age_46s')['qr'] as String); // clock mismatch has the longest next step
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Clock mismatch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the screen shows how many exits are saved on the phone, and the count grows with each scan', (tester) async {
    final now = vectorCase('ok_basic')['now'] as int;
    final log = SqliteScanLog.inMemory();
    addTearDown(log.close);
    final gate = GateController(mode: GateMode.outPass, keys: vec.keysFor([1, 2]), log: log, savedCount: 7, phoneNowS: () => now);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(controller: gate, cameraBuilder: fakeCamera)));
    expect(find.text('7'), findsOneWidget);
    expect(find.text('Saved on this phone'), findsOneWidget);

    feed(vectorCase('ok_basic')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('8'), findsOneWidget);
    expect(await log.count(), 1);
  });

  testWidgets('a valid pass whose exit cannot be saved is red, names the student, and says what to do', (tester) async {
    final log = _FailingLog();
    await pumpScreen(tester, log: log);

    feed(vectorCase('ok_basic')['qr'] as String);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('VALID PASS'), findsNothing);
    expect(find.text('NOT SAVED'), findsOneWidget);
    expect(find.text('Scan not saved'), findsOneWidget);
    expect(find.text('Sample Student'), findsOneWidget);
    expect(find.text('25071A0001'), findsOneWidget);
    expect(find.textContaining('log the student manually'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(savedTime, findsNothing);
    expect(find.text('0'), findsOneWidget);
    expect(overlayColor(tester), CampusColors.light.danger);
  });

  group('ScannerApp', () {
    testWidgets('a valid scan is written to the log it opened, and the count starts from what was already there', (tester) async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      await log.append(const ScanRecord(scanId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', scannedAt: 1, studentId: 5, gate: 'Main', guardId: 'G-DEV'));
      await log.append(const ScanRecord(scanId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', scannedAt: 2, studentId: 6, gate: 'Main', guardId: 'G-DEV'));

      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        identityStore: MemoryIdentityStore(),
        cameraBuilder: fakeCamera,
        openLog: () async => log,
        phoneNowS: () => vec.referenceNow,
      ));
      await settleApp(tester);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Saved on this phone'), findsOneWidget);

      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('VALID PASS'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      final row = (await log.oldest(10)).last;
      expect(row.studentId, 1042);
      expect(row.gate, devGateContext.gate);
      expect(row.guardId, devGateContext.guardId);
    });

    testWidgets('a scanned student appears in the out pass list opened from the scan screen, which cannot export', (tester) async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);

      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        identityStore: MemoryIdentityStore(),
        cameraBuilder: fakeCamera,
        openLog: () async => log,
        phoneNowS: () => vec.referenceNow,
      ));
      await settleApp(tester);
      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4)); // the green screen holds for 3 s
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('VALID PASS'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('open-register')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text("Today's out pass list"), findsOneWidget);
      expect(find.text('1 out'), findsOneWidget);
      final entry = (await log.entries()).single;
      expect(find.text(entry.name), findsOneWidget);

      expect(find.textContaining('Export'), findsNothing);
    });

    testWidgets('if the scan log cannot be opened the scanner stops instead of scanning unrecorded', (tester) async {
      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        identityStore: MemoryIdentityStore(),
        cameraBuilder: _unusedCamera,
        openLog: () async => throw StateError('no space left'),
      ));
      await settleApp(tester);

      expect(find.text("The scanner can't start"), findsOneWidget);
      expect(find.text("Point at the student's QR code"), findsNothing);
    });

    testWidgets('with no key set it refuses to scan and says why', (tester) async {
      await tester.pumpWidget(ScannerApp(cameraBuilder: _unusedCamera, openLog: () async => SqliteScanLog.inMemory(), identityStore: MemoryIdentityStore()));
      await tester.pump();

      expect(find.text('Activate this scanner'), findsOneWidget);
      expect(find.text("Point at the student's QR code"), findsNothing);
    });

    testWidgets('with the dev key set it loads the keys and accepts a demo pass', (tester) async {
      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        identityStore: MemoryIdentityStore(),
        cameraBuilder: fakeCamera,
        openLog: () async => SqliteScanLog.inMemory(),
        phoneNowS: () => vec.referenceNow,
      ));
      await settleApp(tester);

      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(find.text('DEV KEYS'), findsOneWidget);

      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
    });

    testWidgets('a key set that cannot be read stops the scanner instead of scanning without keys', (tester) async {
      await tester.pumpWidget(ScannerApp(keySetSource: const _BrokenKeys(), cameraBuilder: _unusedCamera, openLog: () async => SqliteScanLog.inMemory(), identityStore: MemoryIdentityStore()));
      await settleApp(tester);

      expect(find.text("The scanner can't start"), findsOneWidget);
    });
  });
}

/// A log that is full: every write fails.
class _FailingLog implements ScanLog {
  @override
  Future<void> append(ScanRecord record) async => throw StateError('disk full');

  @override
  Future<int> count() async => 0;

  @override
  Future<List<ScanRecord>> oldest(int limit) async => [];

  @override
  Future<void> remove(Iterable<String> scanIds) async {}

  @override
  Future<void> close() async {}
}

Widget _unusedCamera(BuildContext context, void Function(String) onCode) => const SizedBox();

class _BrokenKeys implements KeySetSource {
  const _BrokenKeys();

  @override
  Future<Never> load() async => throw const FormatException('broken');
}
