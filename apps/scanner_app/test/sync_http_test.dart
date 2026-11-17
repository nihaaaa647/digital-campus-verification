import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/sync_client.dart';
import 'package:scanner_app/src/sync_service.dart';

import 'support/fake_server.dart';

/// The same contract over a real socket: a local HttpServer that checks the token, stores each scan once
/// by id, and answers with the ids it holds. This is what runs on the phone, minus the network.
void main() {
  late HttpServer server;
  late SqliteScanLog log;
  final stored = <String, Map<String, Object?>>{};
  final seenAuth = <String?>[];
  const goodToken = 'good-token';

  Uri url([String path = '/functions/v1/scanner-sync']) => Uri.parse('http://${server.address.host}:${server.port}$path');

  setUp(() async {
    stored.clear();
    seenAuth.clear();
    log = SqliteScanLog.inMemory();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seenAuth.add(request.headers.value('authorization'));
      if (request.method != 'POST' || request.uri.path != '/functions/v1/scanner-sync') {
        request.response.statusCode = 404;
      } else if (request.headers.value('authorization') != 'Bearer $goodToken') {
        request.response.statusCode = 401;
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>;
        final ids = <String>[];
        for (final scan in (body['scans'] as List).cast<Map<String, Object?>>()) {
          final id = scan['scan_id'] as String;
          stored.putIfAbsent(id, () => scan);
          ids.add(id);
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'accepted_scan_ids': ids, 'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000}));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await log.close();
  });

  SyncService serviceFor(SyncConfig config) {
    final service = SyncService(log: log, state: log, client: SyncClient(config, timeout: const Duration(seconds: 3)));
    addTearDown(service.dispose);
    return service;
  }

  test('over real HTTP: the rows arrive once, the phone deletes them, and the clock offset is about zero', () async {
    for (var i = 1; i <= 5; i++) {
      await log.append(row(idOf(i), at: 1793118000 + i));
    }
    await log.append(row(idOf(6), sid: null, roll: '25071A0009', method: EntryMethod.manual));
    final sync = serviceFor(SyncConfig(endpoint: url(), token: goodToken));

    await sync.syncNow();

    expect(sync.phase, SyncPhase.synced);
    expect(await log.count(), 0);
    expect(stored.keys.toSet(), {for (var i = 1; i <= 6; i++) idOf(i)});
    expect(seenAuth.every((a) => a == 'Bearer $goodToken'), isTrue);
    expect(stored[idOf(6)]!['student_id'], isNull, reason: 'a manual entry travels with its roll number only');
    expect(stored[idOf(1)]!['scanned_at'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
    expect((await log.serverOffsetS()).abs(), lessThanOrEqualTo(1), reason: 'the PC clock is the server clock here');
  });

  test('sending the same rows twice leaves one copy on the server', () async {
    await log.append(row(idOf(1)));
    final sync = serviceFor(SyncConfig(endpoint: url(), token: goodToken));
    await sync.syncNow();

    // The phone "forgets" it deleted the row (as if the reply had been lost) and sends it again.
    await log.append(row(idOf(1)));
    await sync.syncNow();

    expect(stored, hasLength(1));
    expect(await log.count(), 0);
  });

  test('a wrong token gets a 401: the rows stay and the scanner says it is not authorised', () async {
    await log.append(row(idOf(1)));
    final sync = serviceFor(SyncConfig(endpoint: url(), token: 'wrong'));

    await sync.syncNow();

    expect(sync.phase, SyncPhase.unauthorized);
    expect(await log.count(), 1);
    expect(stored, isEmpty);
  });

  test('a wrong address gets a 404: the rows stay', () async {
    await log.append(row(idOf(1)));
    final sync = serviceFor(SyncConfig(endpoint: url('/nope'), token: goodToken));

    await sync.syncNow();

    expect(sync.phase, SyncPhase.failed);
    expect(await log.count(), 1);
  });

  test('a server that is not running is "offline", and nothing is lost', () async {
    await log.append(row(idOf(1)));
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = Uri.parse('http://${dead.address.host}:${dead.port}/functions/v1/scanner-sync');
    await dead.close(force: true);
    final sync = serviceFor(SyncConfig(endpoint: deadUrl, token: goodToken));

    await sync.syncNow();

    expect(sync.phase, SyncPhase.offline);
    expect(sync.lastFailure, SyncFailure.network);
    expect(await log.count(), 1);
  });
}
