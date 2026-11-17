import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/app.dart';
import 'package:scanner_app/src/gate_controller.dart';
import 'package:scanner_app/src/gate_result.dart';
import 'package:scanner_app/src/key_set.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/scan_screen.dart';
import 'package:scanner_app/src/scanner_identity.dart';
import 'package:scanner_app/src/sync_client.dart';
import 'package:scanner_app/src/sync_service.dart';

import 'support/disk_bundle.dart';
import 'support/fake_server.dart';
import 'support/vectors.dart';

final _config = SyncConfig(endpoint: Uri.parse('https://example.test/scanner-sync'), token: 'tok');

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

  Future<void> settleApp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  group('the sync pill', () {
    late SqliteScanLog log;
    late FakeServer server;

    setUp(() {
      log = SqliteScanLog.inMemory();
      server = FakeServer();
    });
    tearDown(() => log.close());

    /// Shows the scan screen with a sync service and runs [act] on the service before looking.
    Future<SyncService> show(WidgetTester tester, {SyncClient? client, bool configured = true}) async {
      final gate = GateController(mode: GateMode.outPass, keys: vec.keysFor([1, 2]), log: log, phoneNowS: () => vec.referenceNow);
      final sync = SyncService(
        log: log,
        state: log,
        client: configured ? (client ?? SyncClient(_config, httpClient: server.client)) : null,
        phoneNowMs: () => vec.referenceNow * 1000,
      );
      await tester.pumpWidget(MaterialApp(home: ScanScreen(controller: gate, sync: sync, cameraBuilder: fakeCamera)));
      return sync;
    }

    Future<void> finish(WidgetTester tester, SyncService sync) async {
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
    }

    testWidgets('says sync is off when the build has no server address, and tapping does nothing', (tester) async {
      final sync = await show(tester, configured: false);
      expect(find.text('Sync off'), findsOneWidget);

      await tester.tap(find.text('Sync off'));
      await tester.pump();

      expect(server.calls, 0);
      await finish(tester, sync);
    });

    testWidgets('shows Synced with the time after a good sync', (tester) async {
      final sync = await show(tester);
      await sync.syncNow();
      await tester.pump();

      expect(find.textContaining('Synced'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      await finish(tester, sync);
    });

    testWidgets('shows Offline when the server cannot be reached', (tester) async {
      server.failWith = const SocketException('no route');
      final sync = await show(tester);
      await sync.syncNow();
      await tester.pump();

      expect(find.text('Offline'), findsOneWidget);
      await finish(tester, sync);
    });

    testWidgets('shows Not authorised for a wrong token and Disabled for a disabled scanner', (tester) async {
      server.status = 401;
      final sync = await show(tester);
      await sync.syncNow();
      await tester.pump();
      expect(find.text('Not authorised'), findsOneWidget);

      server.status = 403;
      await sync.syncNow();
      await tester.pump();
      expect(find.text('Disabled'), findsOneWidget);
      await finish(tester, sync);
    });

    testWidgets('shows Sync problem when the server refuses the rows', (tester) async {
      await log.append(row(idOf(1)));
      server.acceptOnly = {};
      final sync = await show(tester);
      await sync.syncNow();
      await tester.pump();

      expect(find.text('Sync problem'), findsOneWidget);
      await finish(tester, sync);
    });

    testWidgets('tapping the pill syncs now', (tester) async {
      server.failWith = const SocketException('no route');
      final sync = await show(tester);
      await sync.syncNow();
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);

      server.failWith = null;
      await tester.tap(find.text('Offline'));
      await tester.pump();
      await tester.pump();

      expect(server.calls, 1);
      expect(find.textContaining('Synced'), findsOneWidget);
      await finish(tester, sync);
    });
  });

  group('ScannerApp with sync', () {
    late SqliteScanLog log;
    late FakeServer server;

    setUp(() {
      log = SqliteScanLog.inMemory();
      server = FakeServer()..serverTimeS = vec.referenceNow;
    });
    tearDown(() => log.close());

    Future<void> launch(WidgetTester tester, {SyncConfig? config}) async {
      await tester.pumpWidget(ScannerApp(
        keySetSource: AssetKeySet(devKeySetAsset, bundle: DiskBundle()),
        identityStore: MemoryIdentityStore(),
        cameraBuilder: fakeCamera,
        openLog: () async => log,
        syncConfig: config,
        httpClient: server.client,
        phoneNowS: () => vec.referenceNow,
      ));
      await settleApp(tester);
    }

    testWidgets('rows left on the phone from earlier are sent when the app starts, and the count drops to zero', (tester) async {
      await log.append(row(idOf(1)));
      await log.append(row(idOf(2)));
      await launch(tester, config: _config);
      expect(find.text('2'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3)); // the first sync starts 2 s after launch
      await tester.pump();

      expect(server.received.keys.toSet(), {idOf(1), idOf(2)});
      expect(await log.count(), 0);
      expect(find.text('0'), findsOneWidget);
      expect(find.textContaining('Synced'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a scan is saved, shown green, and reaches the server a couple of seconds later', (tester) async {
      await launch(tester, config: _config);
      await tester.pump(const Duration(seconds: 3)); // the startup sync, with nothing to send
      await tester.pump();
      expect(server.calls, 1);

      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
      expect(find.text('1'), findsOneWidget, reason: 'one exit on the phone, not yet sent');
      expect(server.calls, 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(server.calls, 2);
      expect((server.requests.last['scans'] as List), hasLength(1));
      expect(await log.count(), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('when the server is down the scan is still saved and shown, and it is sent when the server returns', (tester) async {
      server.failWith = const SocketException('no route');
      await launch(tester, config: _config);

      await outPassMode(tester);
      feed(await tester.runAsync(() => vec.makeQr(ts: vec.referenceNow)) as String);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('VALID PASS'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(await log.count(), 1, reason: 'kept while offline');

      server.failWith = null;
      await tester.pump(const Duration(seconds: 31)); // the first retry delay is 30 s
      await tester.pump();

      expect(await log.count(), 0);
      expect(server.received, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a scanner that is not activated sends nothing, and its pill offers to activate', (tester) async {
      await log.append(row(idOf(1)));
      await launch(tester);
      await tester.pump(const Duration(minutes: 10));

      expect(server.calls, 0);
      expect(await log.count(), 1);
      expect(find.text('Activate'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
