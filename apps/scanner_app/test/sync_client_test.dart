import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/sync_client.dart';

import 'support/fake_server.dart';

final _config = SyncConfig(endpoint: Uri.parse('https://example.test/functions/v1/scanner-sync'), token: 'tok-123');

void main() {
  group('SyncConfig.tryParse', () {
    test('is null when no address was given', () {
      expect(SyncConfig.tryParse('', 'tok'), isNull);
    });

    test('is null for something that is not an address', () {
      expect(SyncConfig.tryParse('not a url', 'tok'), isNull);
      expect(SyncConfig.tryParse('/just/a/path', 'tok'), isNull);
    });

    test('reads an address and a token', () {
      final c = SyncConfig.tryParse('https://x.supabase.co/functions/v1/scanner-sync', 'tok')!;
      expect(c.endpoint.host, 'x.supabase.co');
      expect(c.token, 'tok');
    });
  });

  group('the request', () {
    test('is a POST with the scanner token and a JSON body in the documented shape', () async {
      final server = FakeServer();
      final client = SyncClient(_config, httpClient: server.client);
      final at = DateTime.utc(2026, 10, 27, 16, 47, 4).millisecondsSinceEpoch ~/ 1000;

      await client.sync([row(idOf(1), at: at, sid: 1042, roll: '25071A0001')]);

      expect(server.requestHeaders.single['Authorization'], 'Bearer tok-123');
      expect(server.requestHeaders.single['Content-Type'], startsWith('application/json'));
      expect(server.requests.single, {
        'scans': [
          {
            'scan_id': idOf(1),
            'scanned_at': '2026-10-27T16:47:04Z',
            'student_id': 1042,
            'roll_number': '25071A0001',
            'type': 'OUT',
            'gate': 'Main',
            'guard_id': 'G-03',
            'entry_method': 'scan',
          },
        ],
        'visitors': <Object?>[],
      });
    });

    test('a manual entry carries a roll number and a null student id', () async {
      final server = FakeServer();
      await SyncClient(_config, httpClient: server.client).sync([row(idOf(2), sid: null, roll: '25071A0009', method: EntryMethod.manual)]);

      final scan = (server.requests.single['scans'] as List).single as Map;
      expect(scan['student_id'], isNull);
      expect(scan['roll_number'], '25071A0009');
      expect(scan['entry_method'], 'manual');
    });

    test('with nothing to send it still asks, to exchange the clock', () async {
      final server = FakeServer();
      await SyncClient(_config, httpClient: server.client).sync([]);
      expect(server.requests.single, {'scans': <Object?>[], 'visitors': <Object?>[]});
    });

    test('writes timestamps the way Postgres reads timestamptz', () {
      expect(SyncClient.isoUtc(0), '1970-01-01T00:00:00Z');
      expect(SyncClient.isoUtc(DateTime.utc(2026, 11, 3, 7, 32, 14).millisecondsSinceEpoch ~/ 1000), '2026-11-03T07:32:14Z');
      expect(SyncClient.isoUtc(DateTime.utc(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000), '2026-01-02T03:04:05Z');
    });
  });

  group('the reply', () {
    test('names the accepted ids and the server time; other fields are ignored for now', () async {
      final server = FakeServer()..serverTimeS = 1793118123;
      final reply = await SyncClient(_config, httpClient: server.client).sync([row(idOf(1)), row(idOf(2))]);

      expect(reply.acceptedScanIds, {idOf(1), idOf(2)});
      expect(reply.serverTimeS, 1793118123);
    });

    test('server_time is optional', () async {
      final server = FakeServer()..serverTimeS = null;
      expect((await SyncClient(_config, httpClient: server.client).sync([])).serverTimeS, isNull);
    });

    for (final entry in {
      'not JSON at all': 'hello',
      'a JSON list': '[1,2]',
      'no accepted_scan_ids': '{"server_time": 5}',
      'accepted_scan_ids that is not a list': '{"accepted_scan_ids": "abc"}',
      'accepted_scan_ids holding non-strings': '{"accepted_scan_ids": [1, 2]}',
    }.entries) {
      test('${entry.key} is a bad response, not an acceptance', () async {
        final server = FakeServer()..rawBody = entry.value;
        await expectLater(
          SyncClient(_config, httpClient: server.client).sync([row(idOf(1))]),
          throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.badResponse)),
        );
      });
    }
  });

  group('failures', () {
    Future<SyncFailure> failureFor(MockClient mock) async {
      try {
        await SyncClient(_config, httpClient: mock, timeout: const Duration(milliseconds: 80)).sync([row(idOf(1))]);
      } on SyncException catch (e) {
        return e.failure;
      }
      fail('expected a SyncException');
    }

    test('maps the HTTP statuses the contract documents', () async {
      expect(await failureFor(MockClient((_) async => http.Response('', 401))), SyncFailure.unauthorized);
      expect(await failureFor(MockClient((_) async => http.Response('', 403))), SyncFailure.disabled);
      expect(await failureFor(MockClient((_) async => http.Response('', 500))), SyncFailure.server);
      expect(await failureFor(MockClient((_) async => http.Response('', 503))), SyncFailure.server);
      expect(await failureFor(MockClient((_) async => http.Response('', 429))), SyncFailure.server);
      expect(await failureFor(MockClient((_) async => http.Response('', 404))), SyncFailure.badResponse);
      expect(await failureFor(MockClient((_) async => http.Response('', 400))), SyncFailure.badResponse);
    });

    test('no connection is a network failure', () async {
      expect(await failureFor(MockClient((_) async => throw const SocketException('no route to host'))), SyncFailure.network);
      expect(await failureFor(MockClient((_) async => throw http.ClientException('connection closed'))), SyncFailure.network);
      expect(await failureFor(MockClient((_) async => throw const HandshakeException('bad certificate'))), SyncFailure.network);
    });

    test('a server that never answers is a network failure after the timeout', () async {
      final never = Completer<http.Response>();
      expect(await failureFor(MockClient((_) => never.future)), SyncFailure.network);
    });
  });

  test('a status other than 200 is never treated as a confirmation, even with a convincing body', () async {
    final tricky = MockClient((_) async => http.Response(jsonEncode({'accepted_scan_ids': [idOf(1)]}), 202));
    await expectLater(
      SyncClient(_config, httpClient: tricky).sync([row(idOf(1))]),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.badResponse)),
    );
  });
}
