import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/sync_client.dart';
import 'package:scanner_app/src/sync_service.dart';

import 'support/fake_server.dart';

final _config = SyncConfig(endpoint: Uri.parse('https://example.test/scanner-sync'), token: 'tok');

void main() {
  late SqliteScanLog log;
  late FakeServer server;
  late int phoneMs;
  final offsets = <int>[];
  final pendings = <int>[];

  setUp(() {
    log = SqliteScanLog.inMemory();
    server = FakeServer();
    phoneMs = 1793118000500; // half a second past the second, so the clock arithmetic is exact
    offsets.clear();
    pendings.clear();
  });
  tearDown(() => log.close());

  SyncService make({
    SyncClient? client,
    int batchSize = 100,
    Duration base = const Duration(seconds: 10),
    Duration max = const Duration(seconds: 40),
  }) {
    final service = SyncService(
      log: log,
      state: log,
      client: client ?? SyncClient(_config, httpClient: server.client),
      phoneNowMs: () => phoneMs,
      batchSize: batchSize,
      baseDelay: base,
      maxDelay: max,
      onPending: pendings.add,
      onServerOffset: offsets.add,
    );
    addTearDown(service.dispose);
    return service;
  }

  Future<void> seed(int count) async {
    for (var i = 1; i <= count; i++) {
      await log.append(row(idOf(i), at: 1793118000 + i));
    }
  }

  group('uploading', () {
    test('sends every saved row and deletes them once the server names them', () async {
      await seed(3);
      final sync = make();

      await sync.syncNow();

      expect(server.received.keys.toSet(), {idOf(1), idOf(2), idOf(3)});
      expect(await log.count(), 0);
      expect(sync.phase, SyncPhase.synced);
      expect(sync.pending, 0);
      expect(pendings.last, 0);
    });

    test('sends the rows oldest first and with every field the server needs', () async {
      await seed(2);
      await make().syncNow();

      final sent = (server.requests.first['scans'] as List).cast<Map>();
      expect(sent.map((s) => s['scan_id']), [idOf(1), idOf(2)]);
      expect(sent.first.keys.toSet(), {'scan_id', 'scanned_at', 'student_id', 'roll_number', 'type', 'gate', 'guard_id', 'entry_method'});
    });

    test('splits a large backlog into batches', () async {
      await seed(250);
      await make(batchSize: 100).syncNow();

      expect(server.requests.map((r) => (r['scans'] as List).length), [100, 100, 50]);
      expect(await log.count(), 0);
      expect(server.received, hasLength(250));
    });

    test('with nothing to send it still makes one request, to exchange the clock', () async {
      final sync = make();
      await sync.syncNow();

      expect(server.requests.single['scans'], isEmpty);
      expect(sync.phase, SyncPhase.synced);
      expect(offsets, hasLength(1));
    });

    test('running it twice at once makes one request', () async {
      await seed(1);
      final gate = Completer<void>();
      server.onRequest = (_) => gate.future;
      final sync = make();

      final first = sync.syncNow();
      final second = sync.syncNow();
      await pumpEventQueue();
      gate.complete();
      await Future.wait([first, second]);

      expect(server.calls, 1);
    });
  });

  group('what is deleted', () {
    test('only the rows the server named; the rest stay and the problem is reported', () async {
      await seed(3);
      server.acceptOnly = {idOf(1), idOf(3)};
      final sync = make();

      await sync.syncNow();

      expect((await log.oldest(10)).map((r) => r.scanId), [idOf(2)], reason: 'the refused row must not be lost');
      expect(sync.phase, SyncPhase.failed, reason: 'the second pass was refused entirely');
      expect(sync.lastFailure, SyncFailure.noProgress);
    });

    test('a server that accepts nothing does not make the scanner spin', () async {
      await seed(2);
      server.acceptOnly = {};
      final sync = make();

      await sync.syncNow();

      expect(server.calls, 1);
      expect(await log.count(), 2);
      expect(sync.phase, SyncPhase.failed);
    });

    test('ids in the reply that were not in the request are ignored', () async {
      await seed(3);
      final countsBeforeEachRequest = <int>[];
      server.extraAccepted = [idOf(2), idOf(3)]; // claims rows it was not sent in the first request
      server.onRequest = (_) async => countsBeforeEachRequest.add(await log.count());
      final sync = make(batchSize: 1);

      await sync.syncNow();

      // 3 rows before the first request, 2 before the second: row 2 was not deleted early on the strength
      // of the first reply, it went in a request of its own.
      expect(countsBeforeEachRequest, [3, 2, 1]);
      expect(await log.count(), 0);
    });

    test('a reply that names ids we do not hold changes nothing', () async {
      await seed(1);
      server.extraAccepted = [idOf(99)];
      await make().syncNow();
      expect(await log.count(), 0);
    });

    test('rows saved while a request is in flight are not deleted by it', () async {
      await seed(1);
      var injected = false;
      server.onRequest = (_) async {
        if (injected) return;
        injected = true;
        await log.append(row(idOf(2), at: 1793118999));
      };
      server.extraAccepted = [idOf(2)];
      final sync = make(batchSize: 1);

      // The second row arrives mid-request and the server (wrongly) names it; it must go out in its own request.
      await sync.syncNow();

      expect(server.requests.map((r) => (r['scans'] as List).length), [1, 1]);
      expect(await log.count(), 0);
    });
  });

  group('when it cannot reach the server', () {
    test('keeps every row, reports offline, and sends the same rows later', () async {
      await seed(2);
      server.failWith = const SocketException('no route');
      final sync = make();

      await sync.syncNow();
      expect(await log.count(), 2);
      expect(sync.phase, SyncPhase.offline);

      server.failWith = null;
      await sync.syncNow();
      expect(await log.count(), 0);
      expect(server.received.keys.toSet(), {idOf(1), idOf(2)});
      expect(sync.phase, SyncPhase.synced);
    });

    test('a reply lost after the server stored the rows is harmless: the rows are sent again and not duplicated', () async {
      await seed(2);
      server.loseReply = true;
      final sync = make();

      await sync.syncNow();
      expect(server.received, hasLength(2), reason: 'the server did store them');
      expect(await log.count(), 2, reason: 'the phone cannot know that, so it keeps them');
      expect(sync.phase, SyncPhase.offline);

      server.loseReply = false;
      await sync.syncNow();

      expect(server.requests.map((r) => (r['scans'] as List).map((s) => (s as Map)['scan_id']).toList()), [
        [idOf(1), idOf(2)],
        [idOf(1), idOf(2)],
      ], reason: 'the same rows, with the same ids, so the server can recognise them');
      expect(server.received, hasLength(2), reason: 'no copies');
      expect(await log.count(), 0);
    });

    for (final (status, phase, failure) in [
      (401, SyncPhase.unauthorized, SyncFailure.unauthorized),
      (403, SyncPhase.disabled, SyncFailure.disabled),
      (500, SyncPhase.offline, SyncFailure.server),
      (404, SyncPhase.failed, SyncFailure.badResponse),
    ]) {
      test('HTTP $status keeps the rows and shows $phase', () async {
        await seed(2);
        server.status = status;
        final sync = make();

        await sync.syncNow();

        expect(await log.count(), 2);
        expect(sync.phase, phase);
        expect(sync.lastFailure, failure);
      });
    }

    test('a malformed reply keeps the rows', () async {
      await seed(2);
      server.rawBody = '{"accepted_scan_ids": "everything"}';
      final sync = make();

      await sync.syncNow();

      expect(await log.count(), 2);
      expect(sync.phase, SyncPhase.failed);
    });
  });

  group('the server clock (G14)', () {
    test('stores the offset between the server and the phone, and tells the gate', () async {
      server.serverTimeS = 1793118000 + 40; // the phone is 40 s behind
      final sync = make();

      await sync.syncNow();

      expect(offsets, [40]);
      expect(await log.serverOffsetS(), 40);
      expect(await log.lastSyncAtS(), 1793118000);
      expect(sync.lastSyncAtS, 1793118000);
    });

    test('a phone that is ahead gets a negative offset', () async {
      server.serverTimeS = 1793118000 - 25;
      await make().syncNow();
      expect(offsets, [-25]);
    });

    test('allows for the time the request took', () async {
      server.serverTimeS = 1793118000 + 10;
      server.onRequest = (_) async => phoneMs += 2000; // a slow 2 s round trip: the reply was made 1 s in
      await make().syncNow();

      // The server said ...010 about 1 s after the phone sent the request, so the phone was about 9 s behind.
      expect(offsets, [9]);
    });

    test('a reply without server_time leaves the offset alone', () async {
      await log.saveSync(serverOffsetS: 12, syncedAtS: 5);
      server.serverTimeS = null;
      await make().syncNow();

      expect(offsets, isEmpty);
      expect(await log.serverOffsetS(), 12);
    });

    test('a failed sync does not touch the offset', () async {
      await log.saveSync(serverOffsetS: 12, syncedAtS: 5);
      server.status = 500;
      await make().syncNow();
      expect(await log.serverOffsetS(), 12);
    });
  });

  test('without an address the scanner says sync is off, and keeps everything', () async {
    await seed(2);
    final sync = SyncService(log: log, state: log, client: null);
    addTearDown(sync.dispose);

    sync.start();
    await sync.syncNow();

    expect(sync.phase, SyncPhase.notConfigured);
    expect(await log.count(), 2);
  });

  test('load reads the pending count and the last sync time that were saved', () async {
    await seed(4);
    await log.saveSync(serverOffsetS: 1, syncedAtS: 1793000000);
    final sync = make();

    await sync.load();

    expect(sync.pending, 4);
    expect(sync.lastSyncAtS, 1793000000);
  });

  group('timing', () {
    testWidgets('syncs shortly after a scan is saved, once for a burst', (tester) async {
      final sync = make();
      await sync.load();
      await log.append(row(idOf(1)));
      sync.poke();
      sync.poke();
      sync.poke();
      expect(server.calls, 0);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(server.calls, 1);
      expect(await log.count(), 0);
      sync.dispose(); // otherwise the next scheduled sync is still pending when the test ends
    });

    testWidgets('retries after 10 s, 20 s, 40 s, then stays at the 40 s cap, and recovers when the server does', (tester) async {
      await seed(1);
      var calls = 0;
      var healthy = false;
      final flaky = MockClient((request) async {
        calls++;
        if (!healthy) return http.Response('', 500);
        return server.client.post(request.url, headers: request.headers, body: request.body);
      });
      final sync = make(client: SyncClient(_config, httpClient: flaky), base: const Duration(seconds: 10), max: const Duration(seconds: 40));

      Future<void> advance(int seconds) async {
        await tester.pump(Duration(seconds: seconds));
        await tester.pump();
      }

      await sync.syncNow(); // t = 0: fails
      expect(calls, 1);
      await advance(9);
      expect(calls, 1, reason: 'not before 10 s');
      await advance(1); // t = 10: fails
      expect(calls, 2);
      await advance(19);
      expect(calls, 2, reason: 'the second wait is 20 s');
      await advance(1); // t = 30: fails
      expect(calls, 3);
      await advance(39);
      expect(calls, 3, reason: 'the third wait is 40 s');
      await advance(1); // t = 70: fails
      expect(calls, 4);
      await advance(39);
      expect(calls, 4, reason: 'the wait stays at the 40 s cap');

      healthy = true;
      await advance(1); // t = 110: works
      expect(calls, 5);
      expect(sync.phase, SyncPhase.synced);
      expect(await log.count(), 0);
      sync.dispose();
    });

    testWidgets('after success it syncs again every few minutes to keep the clock fresh', (tester) async {
      final sync = SyncService(
        log: log,
        state: log,
        client: SyncClient(_config, httpClient: server.client),
        phoneNowMs: () => phoneMs,
        idleInterval: const Duration(minutes: 5),
      );

      await sync.syncNow();
      expect(server.calls, 1);
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(server.calls, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(server.calls, 2);
      sync.dispose();
    });

    testWidgets('a wrong token is retried slowly (at the cap), not every few seconds', (tester) async {
      server.status = 401;
      final sync = make(base: const Duration(seconds: 10), max: const Duration(seconds: 40));

      await sync.syncNow();
      await tester.pump(const Duration(seconds: 39));
      await tester.pump();
      expect(sync.phase, SyncPhase.unauthorized);
      expect(server.calls, 0, reason: 'unauthorised replies are refused before the fake records a call');

      server.status = 200;
      await tester.pump(const Duration(seconds: 2)); // 41 s: now it tries again
      await tester.pump();

      expect(sync.phase, SyncPhase.synced);
      sync.dispose();
    });
  });

  test('a disposed service does nothing more', () async {
    final sync = make();
    sync.dispose();
    await sync.syncNow();
    sync.poke();
    expect(server.calls, 0);
  });

  test('works with the plain http client type too', () {
    // SyncClient takes any http.Client: the same type the app uses by default.
    expect(SyncClient(_config, httpClient: http.Client()), isA<SyncClient>());
  });
}
