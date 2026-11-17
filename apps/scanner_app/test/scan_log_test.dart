import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:sqlite3/sqlite3.dart';

ScanRecord record(String id, {int at = 1793118000, int? sid = 1042, String? roll = '25071A0001'}) => ScanRecord(
      scanId: id,
      scannedAt: at,
      studentId: sid,
      rollNumber: roll,
      gate: 'Main',
      guardId: 'G-03',
    );

void main() {
  group('newScanId', () {
    test('is a version 4 UUID in the format the server column expects', () {
      final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (var i = 0; i < 200; i++) {
        expect(newScanId(), matches(uuid));
      }
    });

    test('does not repeat', () {
      expect({for (var i = 0; i < 5000; i++) newScanId()}.length, 5000);
    });
  });

  group('SqliteScanLog', () {
    late SqliteScanLog log;

    setUp(() => log = SqliteScanLog.inMemory());
    tearDown(() => log.close());

    test('starts empty', () async {
      expect(await log.count(), 0);
      expect(await log.oldest(10), isEmpty);
    });

    test('stores a row exactly as given', () async {
      await log.append(record('11111111-1111-4111-8111-111111111111'));

      final rows = await log.oldest(10);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.scanId, '11111111-1111-4111-8111-111111111111');
      expect(r.scannedAt, 1793118000);
      expect(r.studentId, 1042);
      expect(r.rollNumber, '25071A0001');
      expect(r.type, ScanType.out);
      expect(r.gate, 'Main');
      expect(r.guardId, 'G-03');
      expect(r.entryMethod, EntryMethod.scan);
    });

    test('a manual entry may have a roll number and no student id', () async {
      await log.append(const ScanRecord(
        scanId: '22222222-2222-4222-8222-222222222222',
        scannedAt: 1,
        rollNumber: '25071A0009',
        gate: 'Main',
        guardId: 'G-03',
        entryMethod: EntryMethod.manual,
      ));

      final r = (await log.oldest(1)).single;
      expect(r.studentId, isNull);
      expect(r.entryMethod, EntryMethod.manual);
    });

    test('returns rows oldest first and honours the limit', () async {
      for (var i = 1; i <= 5; i++) {
        await log.append(record('0000000$i-0000-4000-8000-000000000000', at: 100 + i));
      }

      final firstTwo = await log.oldest(2);
      expect(firstTwo.map((r) => r.scannedAt), [101, 102]);
      expect(await log.count(), 5);
    });

    test('refuses a duplicate scan id rather than logging an exit twice', () async {
      await log.append(record('33333333-3333-4333-8333-333333333333'));
      await expectLater(log.append(record('33333333-3333-4333-8333-333333333333')), throwsA(isA<SqliteException>()));
      expect(await log.count(), 1);
    });

    test('refuses rows the server would refuse', () async {
      // neither a student id nor a roll number
      await expectLater(log.append(record('44444444-4444-4444-8444-444444444444', sid: null, roll: null)), throwsA(isA<SqliteException>()));
      expect(await log.count(), 0);
    });

    test('remove deletes accepted rows, ignores unknown ids, and can be repeated', () async {
      await log.append(record('00000001-0000-4000-8000-000000000000', at: 1));
      await log.append(record('00000002-0000-4000-8000-000000000000', at: 2));
      await log.append(record('00000003-0000-4000-8000-000000000000', at: 3));

      await log.remove(['00000001-0000-4000-8000-000000000000', '00000003-0000-4000-8000-000000000000', 'no-such-id']);
      await log.remove(['00000001-0000-4000-8000-000000000000']);

      expect((await log.oldest(10)).map((r) => r.scannedAt), [2]);
    });

    test('remove handles more ids than one statement can carry', () async {
      final ids = [for (var i = 0; i < 1200; i++) '${i.toString().padLeft(8, '0')}-0000-4000-8000-000000000000'];
      for (final id in ids) {
        await log.append(record(id));
      }
      await log.remove(ids);
      expect(await log.count(), 0);
    });
  });

  group('sync state', () {
    late SqliteScanLog log;

    setUp(() => log = SqliteScanLog.inMemory());
    tearDown(() => log.close());

    test('a log that has never synced has no offset and no last-sync time', () async {
      expect(await log.serverOffsetS(), 0);
      expect(await log.lastSyncAtS(), isNull);
    });

    test('saves the offset and the time, and overwrites them next time', () async {
      await log.saveSync(serverOffsetS: -7, syncedAtS: 1793118000);
      expect(await log.serverOffsetS(), -7);
      expect(await log.lastSyncAtS(), 1793118000);

      await log.saveSync(serverOffsetS: 2, syncedAtS: 1793118900);
      expect(await log.serverOffsetS(), 2);
      expect(await log.lastSyncAtS(), 1793118900);
    });

    test('is not touched by saving and deleting scans', () async {
      await log.saveSync(serverOffsetS: 5, syncedAtS: 9);
      await log.append(record('11111111-1111-4111-8111-111111111111'));
      await log.remove(['11111111-1111-4111-8111-111111111111']);
      expect(await log.serverOffsetS(), 5);
    });
  });

  group('on disk', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('scan_log_test');
      path = '${dir.path}/scan_log.db';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a row is committed by the time append returns: a second connection sees it', () async {
      final log = SqliteScanLog.open(path);
      addTearDown(log.close);
      await log.append(record('55555555-5555-4555-8555-555555555555'));

      final other = sqlite3.open(path);
      addTearDown(other.close);
      expect(other.select('SELECT count(*) AS n FROM scan_log').first['n'], 1);
    });

    test('rows survive closing and reopening', () async {
      final first = SqliteScanLog.open(path);
      await first.append(record('66666666-6666-4666-8666-666666666666'));
      await first.close();

      final second = SqliteScanLog.open(path);
      addTearDown(second.close);
      expect(await second.count(), 1);
      expect((await second.oldest(1)).single.scanId, '66666666-6666-4666-8666-666666666666');
    });

    test('the file is created with the current schema version and uses WAL', () async {
      final log = SqliteScanLog.open(path);
      await log.close();

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(raw.userVersion, SqliteScanLog.schemaVersion);
      expect(raw.select('PRAGMA journal_mode').first.values.first, 'wal');
    });

    test('a version 1 log (the one already on the phone) is upgraded in place and keeps its rows', () async {
      final raw = sqlite3.open(path);
      raw.execute('''
        CREATE TABLE scan_log (
          seq           INTEGER PRIMARY KEY AUTOINCREMENT,
          scan_id       TEXT    NOT NULL UNIQUE,
          scanned_at    INTEGER NOT NULL,
          student_id    INTEGER,
          roll_number   TEXT,
          type          TEXT    NOT NULL CHECK (type IN ('OUT', 'ENTRY_NO_CARD', 'VISITOR')),
          gate          TEXT    NOT NULL,
          guard_id      TEXT    NOT NULL,
          entry_method  TEXT    NOT NULL CHECK (entry_method IN ('scan', 'manual')),
          CHECK (student_id IS NOT NULL OR roll_number IS NOT NULL)
        )''');
      raw.execute("INSERT INTO scan_log (scan_id, scanned_at, student_id, roll_number, type, gate, guard_id, entry_method) VALUES ('f48b7780-171f-4641-934a-da29b8f4e40c', 1793118424, 1042, '25071A0001', 'OUT', 'Main', 'G-DEV', 'scan')");
      raw.userVersion = 1;
      raw.close();

      final log = SqliteScanLog.open(path);
      addTearDown(log.close);

      expect(await log.count(), 1);
      expect((await log.oldest(1)).single.scanId, 'f48b7780-171f-4641-934a-da29b8f4e40c');
      expect(await log.serverOffsetS(), 0, reason: 'the new table exists and starts empty');
      await log.saveSync(serverOffsetS: 3, syncedAtS: 10);
      expect(await log.serverOffsetS(), 3);

      final check = sqlite3.open(path);
      addTearDown(check.close);
      expect(check.userVersion, SqliteScanLog.schemaVersion);
    });

    test('a log written by a newer app is refused, not silently misread', () async {
      final raw = sqlite3.open(path);
      raw.userVersion = SqliteScanLog.schemaVersion + 1;
      raw.close();

      expect(() => SqliteScanLog.open(path), throwsStateError);
    });
  });
}
