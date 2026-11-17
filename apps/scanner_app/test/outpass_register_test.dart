import 'dart:io';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/gate_controller.dart';
import 'package:scanner_app/src/gate_result.dart';
import 'package:scanner_app/src/outpass_screen.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/vectors.dart';

const _id1 = '11111111-1111-4111-8111-111111111111';
const _id2 = '22222222-2222-4222-8222-222222222222';
const _id3 = '33333333-3333-4333-8333-333333333333';

ScanRecord _exit(String id, {int at = 1793118000, String name = 'Anita Rao', String roll = '25071A0002', String branch = 'ECE', int year = 3, String gate = 'Main'}) => ScanRecord(
      scanId: id,
      scannedAt: at,
      studentId: 2,
      rollNumber: roll,
      gate: gate,
      guardId: 'G-DEV',
      name: name,
      branch: branch,
      year: year,
    );

void main() {
  group('the register in the scan log', () {
    late SqliteScanLog log;
    setUp(() => log = SqliteScanLog.inMemory());
    tearDown(() => log.close());

    test('a scanned exit is written to the queue and the register together, with the student\'s details', () async {
      await log.append(_exit(_id1));
      expect(await log.count(), 1);
      final e = (await log.entries()).single;
      expect(e.name, 'Anita Rao');
      expect(e.rollNumber, '25071A0002');
      expect(e.branch, 'ECE');
      expect(e.year, 3);
      expect(e.gate, 'Main');
      expect(e.guardId, 'G-DEV');
      expect(e.entryMethod, EntryMethod.scan);
      expect(e.scannedAt, 1793118000);
    });

    test('the register keeps an exit after the server has confirmed it and the queue has let go', () async {
      await log.append(_exit(_id1));
      await log.append(_exit(_id2, at: 1793118100, name: 'Ravi Kumar', roll: '25071A0003'));
      await log.remove([_id1, _id2]);

      expect(await log.count(), 0, reason: 'the queue is empty');
      expect((await log.entries()).map((e) => e.name), ['Ravi Kumar', 'Anita Rao'], reason: 'the register is not');
    });

    test('newest first, today only, and a limit', () async {
      await log.append(_exit(_id1, at: 1000));
      await log.append(_exit(_id2, at: 3000));
      await log.append(_exit(_id3, at: 2000));

      expect((await log.entries()).map((e) => e.scanId), [_id2, _id3, _id1]);
      expect((await log.entries(sinceS: 2000)).map((e) => e.scanId), [_id2, _id3]);
      expect((await log.entries(limit: 1)).map((e) => e.scanId), [_id2]);
      expect(await log.registerCount(), 3);
      expect(await log.registerCount(sinceS: 2500), 1);
    });

    test('a manual entry has no details to show, so it is queued but not registered', () async {
      await log.append(const ScanRecord(scanId: _id1, scannedAt: 1, rollNumber: '25071A0002', gate: 'Main', guardId: 'G-DEV', entryMethod: EntryMethod.manual));
      expect(await log.count(), 1);
      expect(await log.entries(), isEmpty);
    });

    test('a repeated scan id is refused and does not leave a second register line', () async {
      await log.append(_exit(_id1));
      await expectLater(log.append(_exit(_id1)), throwsA(anything));
      expect(await log.count(), 1);
      expect(await log.registerCount(), 1);
    });

    test('the details are not part of what is sent to the server', () async {
      await log.append(_exit(_id1));
      final queued = (await log.oldest(1)).single;
      expect(queued.name, isNull);
      expect(queued.scanId, _id1);
    });
  });

  group('the log already on the phone', () {
    late String path;
    setUp(() {
      path = '${Directory.systemTemp.createTempSync('outpass').path}/scan_log.db';
      addTearDown(() => File(path).parent.deleteSync(recursive: true));
    });

    test('a version 2 log is upgraded in place: its rows stay, and the register starts empty', () async {
      final raw = sqlite3.open(path);
      raw.execute('''
        CREATE TABLE scan_log (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, scan_id TEXT NOT NULL UNIQUE, scanned_at INTEGER NOT NULL, student_id INTEGER,
          roll_number TEXT, type TEXT NOT NULL CHECK (type IN ('OUT', 'ENTRY_NO_CARD', 'VISITOR')), gate TEXT NOT NULL,
          guard_id TEXT NOT NULL, entry_method TEXT NOT NULL CHECK (entry_method IN ('scan', 'manual')),
          CHECK (student_id IS NOT NULL OR roll_number IS NOT NULL))''');
      raw.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      raw.execute("INSERT INTO scan_log (scan_id, scanned_at, student_id, roll_number, type, gate, guard_id, entry_method) VALUES ('$_id1', 5, 2, '25071A0002', 'OUT', 'Main', 'G-DEV', 'scan')");
      raw.userVersion = 2;
      raw.close();

      final log = SqliteScanLog.open(path);
      addTearDown(log.close);
      expect(await log.count(), 1);
      expect(await log.entries(), isEmpty);
      await log.append(_exit(_id2));
      expect(await log.registerCount(), 1);
    });
  });

  group('a scan at the gate is registered', () {
    final vec = Vectors.load();

    test('with the name, roll number, branch and year from the pass', () async {
      final ok = vec.verifyCases.firstWhere((c) => (c['expect'] as Map)['result'] == 'OK');
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final gate = GateController(mode: GateMode.outPass, keys: vec.keysFor(ok['keyset'] as List), log: log, phoneNowS: () => ok['now'] as int);
      addTearDown(gate.dispose);

      gate.onCode(ok['qr'] as String);
      await pumpEventQueue();

      final shown = gate.current as dynamic;
      final credential = shown.credential as Credential;
      final entry = (await log.entries()).single;
      expect(entry.name, credential.name);
      expect(entry.rollNumber, credential.roll);
      expect(entry.branch, credential.branch);
      expect(entry.year, credential.year);
    });

    test('and a rejected pass is not', () async {
      final bad = vec.verifyCases.firstWhere((c) => (c['expect'] as Map)['result'] != 'OK');
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final gate = GateController(mode: GateMode.outPass, keys: vec.keysFor(bad['keyset'] as List), log: log, phoneNowS: () => bad['now'] as int);
      addTearDown(gate.dispose);

      gate.onCode(bad['qr'] as String);
      await pumpEventQueue();
      expect(await log.entries(), isEmpty);
    });
  });

  group('what the guard\'s phone keeps', () {
    test('only the last two days: older lines are dropped as new exits come in', () async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      const day = 86400;
      await log.append(_exit(_id1, at: 10 * day));
      await log.append(_exit(_id2, at: 11 * day));
      expect(await log.registerCount(), 2);
      await log.append(_exit(_id3, at: 13 * day));
      expect((await log.entries()).map((e) => e.scanId), [_id3, _id2], reason: 'day 10 is more than two days older than day 13; day 11 is exactly two');
    });

    test('and there is nothing in the app that writes a file or shares one', () {
      final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
      for (final f in sources) {
        final text = f.readAsStringSync();
        expect(text.contains('share_plus'), isFalse, reason: f.path);
        expect(text.contains('Export CSV'), isFalse, reason: f.path);
        expect(text.contains('buildOutpassCsv'), isFalse, reason: f.path);
      }
      expect(File('pubspec.yaml').readAsStringSync().contains('share_plus'), isFalse);
    });
  });

  group('the register screen', () {
    final noon = DateTime(2026, 10, 28, 12);
    int s(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

    Future<SqliteScanLog> logWith(List<ScanRecord> records) async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      for (final r in records) {
        await log.append(r);
      }
      return log;
    }

    testWidgets('lists today\'s exits, newest first, with their details, and nothing from earlier days', (tester) async {
      final log = await logWith([
        _exit(_id1, at: s(DateTime(2026, 10, 28, 9, 5)), name: 'Anita Rao'),
        _exit(_id2, at: s(DateTime(2026, 10, 28, 11, 40)), name: 'Ravi Kumar', roll: '25071A0003', branch: 'CSE', year: 1),
        _exit(_id3, at: s(DateTime(2026, 10, 27, 16)), name: 'Yesterday Person'),
      ]);
      await tester.pumpWidget(MaterialApp(home: OutpassScreen(register: log, phoneNow: () => noon)));
      await tester.pumpAndSettle();

      expect(find.text("Today's out pass list"), findsOneWidget);
      expect(find.text('2 out'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(find.text('25071A0003 · CSE · Year 1'), findsOneWidget);
      expect(find.text('11:40'), findsOneWidget);
      expect(find.text('Yesterday Person'), findsNothing);
      expect(tester.getTopLeft(find.text('Ravi Kumar')).dy, lessThan(tester.getTopLeft(find.text('Anita Rao')).dy));
    });

    testWidgets('is view only: no export, no sharing, and it says where the record is', (tester) async {
      final log = await logWith([_exit(_id1, at: s(DateTime(2026, 10, 28, 9)))]);
      await tester.pumpWidget(MaterialApp(home: OutpassScreen(register: log, phoneNow: () => noon)));
      await tester.pumpAndSettle();

      expect(find.byType(FilledButton), findsNothing);
      expect(find.byIcon(Icons.ios_share_rounded), findsNothing);
      expect(find.textContaining('Export'), findsNothing);
      expect(find.text('View only'), findsOneWidget);
      expect(find.textContaining('CSV export are on the college admin website'), findsOneWidget);
    });

    testWidgets('says so when nobody has gone out', (tester) async {
      final log = await logWith([]);
      await tester.pumpWidget(MaterialApp(home: OutpassScreen(register: log, phoneNow: () => noon)));
      await tester.pumpAndSettle();
      expect(find.text('Nobody has gone out today'), findsOneWidget);
    });
  });
}
