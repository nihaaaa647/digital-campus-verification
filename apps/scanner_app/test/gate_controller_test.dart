import 'dart:async';
import 'dart:io';

import 'package:credential_core/credential_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/gate_controller.dart';
import 'package:scanner_app/src/gate_result.dart';
import 'package:scanner_app/src/scan_log.dart';

import 'support/vectors.dart';

/// A log whose writes the test controls: they wait until [release] is called, or fail if [failWith] is set.
class _ControlledLog implements ScanLog {
  _ControlledLog(this.inner);

  final ScanLog inner;
  final List<String> events = [];
  Completer<void>? gate;
  Object? failWith;

  @override
  Future<void> append(ScanRecord record) async {
    events.add('append');
    await gate?.future;
    final error = failWith;
    if (error != null) throw error;
    await inner.append(record);
    events.add('committed');
  }

  @override
  Future<int> count() => inner.count();

  @override
  Future<List<ScanRecord>> oldest(int limit) => inner.oldest(limit);

  @override
  Future<void> remove(Iterable<String> scanIds) => inner.remove(scanIds);

  @override
  Future<void> close() => inner.close();
}

void main() {
  final vec = Vectors.load();

  SqliteScanLog newLog() {
    final log = SqliteScanLog.inMemory();
    addTearDown(log.close);
    return log;
  }

  group('every shared verify case gives the guard the right screen', () {
    for (final c in vec.verifyCases) {
      test(c['id'] as String, () async {
        final keys = vec.keysFor(c['keyset'] as List);
        var revoked = <RevocationEntry>[];
        if (c['revocation'] != null) {
          revoked = (verifyRevocationList(c['revocation'] as String, keys) as RevocationAccepted).list.entries;
        }
        final log = newLog();
        final gate = GateController(mode: GateMode.outPass, keys: keys, log: log, revoked: revoked, phoneNowS: () => c['now'] as int);
        addTearDown(gate.dispose);

        gate.onCode(c['qr'] as String);
        await pumpEventQueue();

        final expected = c['expect'] as Map<String, dynamic>;
        final shown = gate.current;
        if (expected['result'] == 'OK') {
          expect(shown, isA<GateAccepted>());
          final credential = (shown as GateAccepted).credential;
          final want = expected['credential'] as Map<String, dynamic>;
          expect(credential.sid, want['sid']);
          expect(credential.roll, want['roll']);
          expect(credential.name, want['name']);
          expect(await log.count(), 1, reason: 'every green screen has a saved row behind it');
        } else {
          expect(shown, isA<GateRejected>());
          expect((shown as GateRejected).failure.code, expected['result']);
          expect(shown.red.title, isNotEmpty);
          expect(shown.red.nextStep, isNotEmpty);
          expect(await log.count(), 0, reason: 'a rejected pass is not an exit');
        }
      });
    }
  });

  group('red screen wording', () {
    // docs/credential-spec.md section 9 is the source of the titles; this keeps the app from drifting.
    final spec = _findSpec().readAsLinesSync();
    final start = spec.indexWhere((l) => l.startsWith('### Result codes and the guard'));
    final rows = <String, String>{}; // result code -> red screen title in the spec
    for (final line in spec.skip(start + 1)) {
      if (line.startsWith('#')) break;
      final cells = line.split('|').map((s) => s.trim()).toList();
      if (cells.length < 5 || !cells[1].startsWith('`')) continue;
      for (final m in RegExp(r'`([A-Z_]+)`').allMatches(cells[1])) {
        rows[m.group(1)!] = cells[2];
      }
    }

    test('the spec table was found and covers every failure the scanner can show', () {
      expect(rows.keys.toSet(), ScanFailure.values.map((f) => f.code).toSet());
    });

    for (final f in ScanFailure.values) {
      test('${f.code} uses the spec title', () {
        expect(redScreenFor(f).title, rows[f.code]);
        expect(redScreenFor(f).nextStep.length, greaterThan(10));
      });
    }
  });

  group('at the gate', () {
    late int now;
    late GateController gate;
    late SqliteScanLog log;

    setUp(() {
      now = vec.referenceNow;
      log = newLog();
    });

    GateController make({int offset = 0, int Function()? phone, ScanLog? useLog, String Function()? newId}) {
      gate = GateController(
        mode: GateMode.outPass,
        keys: vec.keysFor([1, 2]),
        log: useLog ?? log,
        serverOffsetS: offset,
        phoneNowS: phone ?? () => now,
        newId: newId,
      );
      addTearDown(gate.dispose);
      return gate;
    }

    testWidgets('green holds for 3 s, red for 6 s, then back to scanning', (tester) async {
      make();
      gate.onCode(await vec.makeQr(ts: now));
      await tester.pump();
      expect(gate.current, isA<GateAccepted>());
      await tester.pump(const Duration(seconds: 2, milliseconds: 900));
      expect(gate.current, isA<GateAccepted>());
      await tester.pump(const Duration(milliseconds: 200));
      expect(gate.current, isNull);

      gate.onCode('not a campus pass');
      expect(gate.current, isA<GateRejected>());
      await tester.pump(const Duration(seconds: 5, milliseconds: 900));
      expect(gate.current, isA<GateRejected>());
      await tester.pump(const Duration(milliseconds: 200));
      expect(gate.current, isNull);
    });

    test('a tap goes straight back to scanning, and tapping an empty screen does nothing', () async {
      make();
      gate.dismiss();
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      expect(gate.current, isNotNull);
      gate.dismiss();
      expect(gate.current, isNull);
    });

    test('codes read while a result is showing are ignored', () async {
      make();
      gate.onCode(await vec.makeQr(ts: now, sid: 1, roll: 'A1', name: 'First'));
      await pumpEventQueue();
      gate.onCode(await vec.makeQr(ts: now, sid: 2, roll: 'B2', name: 'Second'));
      await pumpEventQueue();
      expect((gate.current as GateAccepted).credential.name, 'First');
      expect(await log.count(), 1);
    });

    test('the same QR still in front of the camera is not scanned twice', () async {
      make();
      final qr = await vec.makeQr(ts: now);
      gate.onCode(qr);
      await pumpEventQueue();
      gate.dismiss();
      now += 20; // still inside the time window, so verifyScan would accept it again
      gate.onCode(qr);
      await pumpEventQueue();
      expect(gate.current, isNull);
      expect(await log.count(), 1, reason: 'one exit, one row');
    });

    test('a refreshed QR from the same student is a duplicate for 5 s, then a new scan', () async {
      make();
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      gate.dismiss();

      now += 4;
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      expect(gate.current, isNull, reason: '4 s after the first scan');
      expect(await log.count(), 1);

      now += 2; // 6 s after the first scan
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      expect(gate.current, isA<GateAccepted>());
      expect(await log.count(), 2);
    });

    test('a different student right behind is scanned at once', () async {
      make();
      gate.onCode(await vec.makeQr(ts: now, sid: 1, roll: 'A1', name: 'First'));
      await pumpEventQueue();
      gate.dismiss();
      gate.onCode(await vec.makeQr(ts: now, sid: 2, roll: 'B2', name: 'Second'));
      await pumpEventQueue();
      expect((gate.current as GateAccepted).credential.name, 'Second');
      expect(await log.count(), 2);
    });

    test('a rejected code held in front of the camera shows red once, not on every frame', () async {
      make();
      gate.onCode('DC1.garbage');
      gate.dismiss();
      gate.onCode('DC1.garbage');
      expect(gate.current, isNull);

      now += 6;
      gate.onCode('DC1.garbage');
      expect(gate.current, isA<GateRejected>());
      expect(await log.count(), 0);
    });

    test('the server-time offset corrects a wrong scanner clock', () async {
      final qr = await vec.makeQr(ts: now);
      make(phone: () => now - 100); // scanner clock 100 s slow
      gate.onCode(qr);
      await pumpEventQueue();
      expect((gate.current as GateRejected).failure, ScanFailure.clockMismatch);

      make(offset: 100, phone: () => now - 100);
      gate.onCode(qr);
      await pumpEventQueue();
      expect(gate.current, isA<GateAccepted>());
      expect((await log.oldest(1)).single.scannedAt, now, reason: 'the row carries the corrected time');
    });

    test('a controller that was disposed ignores late camera frames', () async {
      final late = GateController(mode: GateMode.outPass, keys: vec.keysFor([1, 2]), log: log, phoneNowS: () => now);
      final qr = await vec.makeQr(ts: now);
      late.dispose();
      late.onCode(qr);
      late.dismiss();
      await pumpEventQueue();
      expect(await log.count(), 0);
    });
  });

  group('saving the exit (G7)', () {
    late int now;
    late SqliteScanLog inner;
    late _ControlledLog log;

    setUp(() {
      now = vec.referenceNow;
      inner = newLog();
      log = _ControlledLog(inner);
    });

    GateController make({String Function()? newId, GateContext context = const GateContext(gate: 'North', guardId: 'G-03')}) {
      final g = GateController(
        mode: GateMode.outPass,
        keys: vec.keysFor([1, 2]),
        log: log,
        context: context,
        phoneNowS: () => now,
        newId: newId,
      );
      addTearDown(g.dispose);
      return g;
    }

    test('the row carries the student, the corrected time, the gate and the guard', () async {
      final gate = make(newId: () => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      gate.onCode(await vec.makeQr(ts: now, sid: 1042, roll: '25071A0001'));
      await pumpEventQueue();

      final row = (await inner.oldest(5)).single;
      expect(row.scanId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(row.studentId, 1042);
      expect(row.rollNumber, '25071A0001');
      expect(row.scannedAt, now);
      expect(row.type, ScanType.out);
      expect(row.entryMethod, EntryMethod.scan);
      expect(row.gate, 'North');
      expect(row.guardId, 'G-03');
    });

    test('the row is committed before the green screen is shown', () async {
      final gate = make();
      gate.addListener(() => log.events.add(gate.current is GateAccepted ? 'green shown' : 'cleared'));

      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();

      expect(log.events, ['append', 'committed', 'green shown']);
    });

    test('while the write is in flight nothing is shown and further codes are ignored', () async {
      final gate = make();
      log.gate = Completer<void>();

      gate.onCode(await vec.makeQr(ts: now, sid: 1, roll: 'A1', name: 'First'));
      await pumpEventQueue();
      expect(gate.current, isNull, reason: 'no green until the row is on disk');

      gate.onCode(await vec.makeQr(ts: now, sid: 2, roll: 'B2', name: 'Second'));
      await pumpEventQueue();
      expect(log.events.where((e) => e == 'append'), hasLength(1), reason: 'the second code is not even tried');

      log.gate!.complete();
      await pumpEventQueue();
      expect((gate.current as GateAccepted).credential.name, 'First');
      expect(gate.savedCount, 1);
    });

    test('if the row cannot be written the guard sees red, never green, and the count does not move', () async {
      final gate = make();
      log.failWith = StateError('disk full');

      gate.onCode(await vec.makeQr(ts: now, sid: 1042, roll: '25071A0001', name: 'Sample Student'));
      await pumpEventQueue();

      final shown = gate.current;
      expect(shown, isA<GateNotSaved>());
      expect((shown as GateNotSaved).credential.name, 'Sample Student');
      expect(shown.red.title, 'Scan not saved');
      expect(gate.savedCount, 0);
      expect(await inner.count(), 0);
    });

    test('after a failed write the same student can be scanned again once it works', () async {
      final gate = make();
      log.failWith = StateError('disk full');
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      gate.dismiss();

      log.failWith = null;
      now += 6; // past the 5 s that stops one bad code flashing on every frame
      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();

      expect(gate.current, isA<GateAccepted>());
      expect(await inner.count(), 1);
      expect(gate.savedCount, 1);
    });

    test('a failed write is not retried on every camera frame', () async {
      final gate = make();
      log.failWith = StateError('disk full');
      final qr = await vec.makeQr(ts: now);

      gate.onCode(qr);
      await pumpEventQueue();
      gate.dismiss();
      gate.onCode(qr);
      await pumpEventQueue();

      expect(log.events.where((e) => e == 'append'), hasLength(1));
    });

    test('every saved scan gets its own id, and the saved count follows the log', () async {
      final gate = make();
      for (var sid = 1; sid <= 3; sid++) {
        gate.onCode(await vec.makeQr(ts: now, sid: sid, roll: 'R$sid', name: 'S$sid'));
        await pumpEventQueue();
        gate.dismiss();
      }

      final ids = (await inner.oldest(10)).map((r) => r.scanId).toSet();
      expect(ids, hasLength(3));
      expect(gate.savedCount, 3);
    });

    test('the saved count starts from what is already in the log', () async {
      await inner.append(const ScanRecord(scanId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', scannedAt: 1, studentId: 1, gate: 'Main', guardId: 'G-03'));
      final gate = GateController(mode: GateMode.outPass, keys: vec.keysFor([1, 2]), log: log, savedCount: await log.count(), phoneNowS: () => now);
      addTearDown(gate.dispose);

      gate.onCode(await vec.makeQr(ts: now));
      await pumpEventQueue();
      expect(gate.savedCount, 2);
    });
  });
}

File _findSpec() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/docs/credential-spec.md');
    if (f.existsSync()) return f;
    dir = dir.parent;
  }
  throw StateError('docs/credential-spec.md not found above ${Directory.current.path}');
}
