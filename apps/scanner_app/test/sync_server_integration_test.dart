// The Dart scanner against the real scanner-sync handler, SQL and database (supabase/functions/dev).
// It is skipped unless a server is running and its address is given:
//
//   cd supabase/functions && npm run dev:scanner-sync
//   cd apps/scanner_app
//   DCID_SYNC_SERVER_URL=http://127.0.0.1:8787/functions/v1/scanner-sync flutter test test/sync_server_integration_test.dart
//
// (PowerShell: $env:DCID_SYNC_SERVER_URL = '...'; flutter test test/sync_server_integration_test.dart)
// It uses the development scanner token and guard from supabase/seed.sql.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/sync_client.dart';
import 'package:scanner_app/src/sync_service.dart';

final String? _url = Platform.environment['DCID_SYNC_SERVER_URL'];

Future<Map<String, Object?>> _serverScans() async {
  final base = Uri.parse(_url!);
  final client = HttpClient();
  try {
    final request = await client.getUrl(base.replace(path: '/_dev/scans'));
    final response = await request.close();
    return jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
  } finally {
    client.close();
  }
}

ScanRecord _scan({required String id, int? sid = 1042, String? roll = '25071A0001', String guard = 'G-DEV', EntryMethod method = EntryMethod.scan, int at = 1793118000}) {
  return ScanRecord(scanId: id, scannedAt: at, studentId: sid, rollNumber: roll, gate: 'Main', guardId: guard, entryMethod: method);
}

void main() {
  test(
    'syncs into the real function: rows are stored once, resolved to the student, and deleted from the phone',
    () async {
      final before = (await _serverScans())['count'] as int;
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final service = SyncService(log: log, state: log, client: SyncClient(SyncConfig(endpoint: Uri.parse(_url!), token: 'dev-token')));
      addTearDown(service.dispose);

      final good = [newScanId(), newScanId(), newScanId()];
      final manual = newScanId();
      final refused = newScanId();
      for (final (i, id) in good.indexed) {
        await log.append(_scan(id: id, at: 1793118000 + i));
      }
      await log.append(_scan(id: manual, sid: null, roll: '25071a0001', method: EntryMethod.manual, at: 1793118100)); // lower case: the server normalises
      await log.append(_scan(id: refused, guard: 'G-NOT-A-GUARD', at: 1793118200));

      await service.syncNow();

      // The row the server refuses stays; everything else is gone from the phone.
      expect((await log.oldest(10)).map((r) => r.scanId), [refused]);
      expect(service.lastFailure, SyncFailure.noProgress, reason: 'the last pass held only the refused row');
      expect(service.phase, SyncPhase.failed);

      final server = await _serverScans();
      expect(server['count'], before + 4);
      final stored = (server['scans'] as List).cast<Map<String, Object?>>().where((s) => [...good, manual].contains(s['scan_id'])).toList();
      expect(stored, hasLength(4));
      for (final s in stored) {
        expect(s['scanner_id'], 'SC-DEV', reason: 'taken from the token');
        expect(s['student_id'], isNotNull, reason: 'the student id on the pass is not on the roster, so it is found by roll number');
        expect(s['roll_number'], '25071A0001', reason: 'normalised to upper case');
        expect(s['guard_id'], 'G-DEV');
      }
      expect(stored.where((s) => s['entry_method'] == 'manual'), hasLength(1));
      expect((await log.serverOffsetS()).abs(), lessThanOrEqualTo(2), reason: 'the server and this PC share a clock');

      // The reply to that first attempt "was lost": the phone has the rows again and sends them once more.
      for (final (i, id) in good.indexed) {
        await log.append(_scan(id: id, at: 1793118000 + i));
      }
      await service.syncNow();

      expect((await _serverScans())['count'], before + 4, reason: 'no duplicates on the server');
      expect((await log.oldest(10)).map((r) => r.scanId), [refused]);
    },
    skip: _url == null ? 'set DCID_SYNC_SERVER_URL to run against a local scanner-sync (see the top of this file)' : false,
  );
}
