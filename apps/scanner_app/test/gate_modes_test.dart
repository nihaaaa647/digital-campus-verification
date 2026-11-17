import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/gate_controller.dart';
import 'package:scanner_app/src/gate_result.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/scan_screen.dart';

import 'support/vectors.dart';

/// A log that must never be written to: verify mode records nothing.
class _NeverWrittenLog implements ScanLog {
  int appends = 0;

  @override
  Future<void> append(ScanRecord record) async {
    appends++;
    throw StateError('verify mode wrote an exit');
  }

  @override
  Future<int> count() async => 0;

  @override
  Future<List<ScanRecord>> oldest(int limit) async => [];

  @override
  Future<void> remove(Iterable<String> scanIds) async {}

  @override
  Future<void> close() async {}
}

void main() {
  final vec = Vectors.load();
  Map<String, dynamic> vectorCase(String id) => vec.verifyCases.firstWhere((c) => c['id'] == id) as Map<String, dynamic>;
  final ok = vectorCase('ok_basic');
  final okQr = ok['qr'] as String;
  final now = ok['now'] as int;

  GateController newGate(ScanLog log, {GateMode? mode, VoidCallback? onSaved, int Function()? clock}) {
    final gate = GateController(
      keys: vec.keysFor([1, 2]),
      log: log,
      onSaved: onSaved,
      phoneNowS: clock ?? () => now,
      acceptedHold: const Duration(seconds: 3),
      mode: mode ?? GateMode.verify,
    );
    addTearDown(gate.dispose);
    return gate;
  }

  group('verify mode, which is how the scanner starts', () {
    test('a controller with no mode given only verifies', () {
      final gate = GateController(keys: vec.keysFor([1, 2]), log: _NeverWrittenLog(), phoneNowS: () => now);
      addTearDown(gate.dispose);
      expect(gate.mode, GateMode.verify);
    });

    test('a valid pass is shown green but nothing is written, counted, or sent', () async {
      final log = _NeverWrittenLog();
      var saved = 0;
      final gate = newGate(log, onSaved: () => saved++);

      gate.onCode(okQr);
      await pumpEventQueue();

      final shown = gate.current;
      expect(shown, isA<GateAccepted>());
      expect((shown as GateAccepted).recorded, isFalse);
      expect(shown.credential.name, isNotEmpty);
      expect(log.appends, 0);
      expect(gate.savedCount, 0);
      expect(saved, 0, reason: 'so no sync is started either');
    });

    test('a log that is broken does not matter: a check is not a write', () async {
      final gate = newGate(_NeverWrittenLog());
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(gate.current, isA<GateAccepted>(), reason: 'not the red "not saved" screen');
    });

    test('the same pass in front of the camera does not flash again at once, but can be checked again after a few seconds', () async {
      var t = now;
      final gate = newGate(SqliteScanLog.inMemory(), clock: () => t);
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(gate.current, isNotNull);
      gate.dismiss();

      gate.onCode(okQr);
      await pumpEventQueue();
      expect(gate.current, isNull, reason: 'still inside the 5 s window');

      t = now + GateController.sameStudentDebounceS + 1;
      gate.onCode(vectorCase('ok_basic')['qr'] as String);
      await pumpEventQueue();
      // The code is older than the window by now (it is 45 s old at most), so this is only a check that it is not
      // silently ignored forever: either green or a clock-mismatch red, but something is shown.
      expect(gate.current, isNotNull);
    });

    test('a bad pass is red in verify mode too', () async {
      final bad = vec.verifyCases.firstWhere((c) => (c['expect'] as Map)['result'] != 'OK') as Map<String, dynamic>;
      final gate = GateController(keys: vec.keysFor(bad['keyset'] as List), log: _NeverWrittenLog(), phoneNowS: () => bad['now'] as int);
      addTearDown(gate.dispose);
      gate.onCode(bad['qr'] as String);
      await pumpEventQueue();
      expect(gate.current, isA<GateRejected>());
    });
  });

  group('out pass mode', () {
    test('records the exit: written, counted, listed and handed to the sync', () async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      var saved = 0;
      final gate = newGate(log, mode: GateMode.outPass, onSaved: () => saved++);

      gate.onCode(okQr);
      await pumpEventQueue();

      expect((gate.current as GateAccepted).recorded, isTrue);
      expect(await log.count(), 1);
      expect(await log.registerCount(), 1);
      expect(gate.savedCount, 1);
      expect(saved, 1);
    });

    test('a failed write is the red "not saved" screen, as before', () async {
      final gate = newGate(_NeverWrittenLog(), mode: GateMode.outPass);
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(gate.current, isA<GateNotSaved>());
    });
  });

  group('switching', () {
    test('a pass that was only verified can be recorded at once by switching and scanning it again', () async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final gate = newGate(log);

      gate.onCode(okQr);
      await pumpEventQueue();
      expect(await log.count(), 0);

      gate.setMode(GateMode.outPass);
      expect(gate.current, isNull, reason: 'the green screen is dismissed by the switch');
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(await log.count(), 1);
      expect((gate.current as GateAccepted).recorded, isTrue);
    });

    test('switching back stops recording', () async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final gate = newGate(log, mode: GateMode.outPass);
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(await log.count(), 1);

      gate.setMode(GateMode.verify);
      gate.onCode(okQr);
      await pumpEventQueue();
      expect(await log.count(), 1, reason: 'the second look was only a check');
      expect((gate.current as GateAccepted).recorded, isFalse);
    });

    test('it tells listeners, once, and ignores a switch to the mode it is already in', () {
      final gate = newGate(SqliteScanLog.inMemory());
      var calls = 0;
      gate.addListener(() => calls++);
      gate.setMode(GateMode.verify);
      expect(calls, 0);
      gate.setMode(GateMode.outPass);
      expect(calls, 1);
      expect(gate.mode, GateMode.outPass);
    });

    test('it does nothing after the controller is gone', () {
      final gate = GateController(keys: vec.keysFor([1, 2]), log: _NeverWrittenLog(), phoneNowS: () => now);
      gate.dispose();
      expect(() => gate.setMode(GateMode.outPass), returnsNormally);
    });
  });

  group('what the guard sees', () {
    late void Function(String) feed;

    Widget fakeCamera(BuildContext context, void Function(String) onCode) {
      feed = onCode;
      return const ColoredBox(color: Colors.black54);
    }

    Future<GateController> pump(WidgetTester tester) async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final gate = GateController(keys: vec.keysFor([1, 2]), log: log, phoneNowS: () => now);
      await tester.pumpWidget(MaterialApp(home: ScanScreen(controller: gate, cameraBuilder: fakeCamera)));
      return gate;
    }

    testWidgets('the switch is at the top, starts on Verify, and the hint says what a scan will do', (tester) async {
      final gate = await pump(tester);
      expect(find.byKey(const ValueKey('mode-verify')), findsOneWidget);
      expect(find.byKey(const ValueKey('mode-outpass')), findsOneWidget);
      expect(find.text("Point at the student's QR code"), findsOneWidget);
      expect(gate.mode, GateMode.verify);

      await tester.tap(find.byKey(const ValueKey('mode-outpass')));
      await tester.pump();
      expect(gate.mode, GateMode.outPass);
      expect(find.text('Out pass mode · each scan is recorded'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mode-verify')));
      await tester.pump();
      expect(gate.mode, GateMode.verify);
      expect(find.text("Point at the student's QR code"), findsOneWidget);
    });

    testWidgets('a verify scan says it was only checked; an out pass scan says it was recorded', (tester) async {
      final gate = await pump(tester);

      feed(okQr);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
      expect(find.text('VERIFY ONLY · NOT RECORDED'), findsOneWidget);
      expect(find.textContaining('not recorded'), findsWidgets);
      expect(find.text('OUT PASS RECORDED'), findsNothing);
      expect(find.text('0'), findsOneWidget, reason: 'the saved count did not move');

      gate.dismiss();
      await tester.pump(); // an animation starts on the frame after it is asked for
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('mode-outpass')));
      await tester.pump();
      feed(okQr);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
      expect(find.text('OUT PASS RECORDED'), findsOneWidget);
      expect(find.text('VERIFY ONLY · NOT RECORDED'), findsNothing);
      expect(find.text('1'), findsOneWidget, reason: 'the saved count moved');
    });

    testWidgets('switching modes with a result on screen takes it away', (tester) async {
      final gate = await pump(tester);
      feed(okQr);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);

      gate.setMode(GateMode.outPass);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('VALID PASS'), findsNothing);
    });

    testWidgets('both modes fit a small phone with large text', (tester) async {
      tester.view.physicalSize = const Size(960, 1707); // 320 x 569 dp at 3x
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      final gate = await pump(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('mode-outpass')));
      await tester.pump();
      expect(gate.mode, GateMode.outPass);
      expect(tester.takeException(), isNull);
    });
  });
}
