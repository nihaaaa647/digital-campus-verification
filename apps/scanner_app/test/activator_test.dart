import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/activation_client.dart';
import 'package:scanner_app/src/activator.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/scanner_identity.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/fake_backend.dart';
import 'support/vectors.dart';

void main() {
  final vec = Vectors.load();

  group('ScannerIdentity', () {
    final identity = ScannerIdentity(serverBase: Uri.parse('https://xyz.supabase.co'), scannerId: 'SC-01', name: 'Main gate 1', gate: 'Main', token: 'tok-123');

    test('is saved as JSON and read back the same', () {
      final back = ScannerIdentity.tryParse(identity.toJson())!;
      expect(back.serverBase.toString(), 'https://xyz.supabase.co');
      expect((back.scannerId, back.name, back.gate, back.token), ('SC-01', 'Main gate 1', 'Main', 'tok-123'));
    });

    test('knows where to sync, and keeps its token for it', () {
      expect(identity.syncEndpoint.toString(), 'https://xyz.supabase.co/functions/v1/scanner-sync');
      expect(identity.syncConfig.token, 'tok-123');
      final prefixed = ScannerIdentity(serverBase: Uri.parse('https://example.org/api'), scannerId: 'a', name: 'b', gate: 'c', token: 'd');
      expect(prefixed.syncEndpoint.toString(), 'https://example.org/api/functions/v1/scanner-sync');
    });

    test('anything that is not a saved identity reads as none, not as a crash', () {
      for (final bad in [null, '', 'garbage', '[]', '{}', '{"server":"https://x.org"}', '{"server":"https://x.org","scanner_id":"a","name":"b","gate":"c","token":""}', '{"server":"nothing","scanner_id":"a","name":"b","gate":"c","token":"t"}']) {
        expect(ScannerIdentity.tryParse(bad), isNull, reason: '$bad');
      }
    });

    test('the in-memory store saves, loads and clears', () async {
      final store = MemoryIdentityStore();
      expect(await store.load(), isNull);
      await store.save(identity);
      expect((await store.load())!.token, 'tok-123');
      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  group('the key set kept by the log', () {
    test('is empty until activation stores one, then comes back as it was sent', () async {
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      expect(await log.storedKeySet(), isNull);

      final keySet = Map<String, Object?>.from(vec.json['keyset_json'] as Map);
      await log.saveKeySet(keySet);
      expect(await log.storedKeySet(), keySet);

      await log.saveKeySet({'v': 1, 'current': 5, 'keys': <Object?>[]});
      expect((await log.storedKeySet())!['current'], 5, reason: 'a new key set replaces the old');
    });

    test('survives closing and reopening the log', () async {
      final dir = Directory.systemTemp.createTempSync('keyset_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = SqliteScanLog.open('${dir.path}/log.db');
      await first.saveKeySet({'v': 1, 'current': 2, 'keys': <Object?>[]});
      await first.close();

      final second = SqliteScanLog.open('${dir.path}/log.db');
      addTearDown(second.close);
      expect((await second.storedKeySet())!['current'], 2);
    });

    test('a damaged value reads as no key set', () async {
      final dir = Directory.systemTemp.createTempSync('keyset_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      SqliteScanLog.open('${dir.path}/log.db').close();
      final raw = sqlite3.open('${dir.path}/log.db');
      raw.execute("INSERT INTO meta (key, value) VALUES ('keyset_json', '{not json')");
      raw.close();

      final log = SqliteScanLog.open('${dir.path}/log.db');
      addTearDown(log.close);
      expect(await log.storedKeySet(), isNull);
    });
  });

  group('Activator', () {
    late FakeBackend backend;
    late MemoryIdentityStore identities;
    late SqliteScanLog log;

    setUp(() {
      backend = FakeBackend(vec);
      identities = MemoryIdentityStore();
      log = SqliteScanLog.inMemory();
    });
    tearDown(() => log.close());

    Activator make({bool allowInsecure = false, IdentityStore? store}) =>
        Activator(identityStore: store ?? identities, keyStore: log, httpClient: backend.client, allowInsecure: allowInsecure);

    test('swaps the code for an identity and keys, and keeps both', () async {
      final result = await make().activate(server: 'xyz.supabase.co', code: 'k7qm-29xd');

      expect(result, isA<Activated>());
      final done = result as Activated;
      expect(done.identity.serverBase.toString(), 'https://xyz.supabase.co');
      expect((done.identity.scannerId, done.identity.gate, done.identity.token), ('SC-NEW', 'North gate', backend.token));
      expect(done.keys.keys.toSet(), {1, 2});

      expect((await identities.load())!.token, backend.token);
      expect(await log.storedKeySet(), backend.keySet);
      expect(backend.activations.single.url.toString(), 'https://xyz.supabase.co/functions/v1/scanner-activate');
    });

    test('the same code a second time is refused and changes nothing', () async {
      await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
      backend.token = 'a-different-token-${'B' * 30}';

      final again = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');

      expect(again, isA<ActivationFailed>());
      expect((await identities.load())!.token, startsWith('tok-'), reason: 'the first token is still the saved one');
    });

    group('keeps nothing when it does not work', () {
      Future<void> expectNothingSaved() async {
        expect(await identities.load(), isNull);
        expect(await log.storedKeySet(), isNull);
      }

      test('a wrong code', () async {
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'ZZZZ-ZZZZ');
        expect((result as ActivationFailed).message, activationMessage(ActivationFailure.invalidCode));
        await expectNothingSaved();
      });

      test('a code that cannot be one is refused before any request', () async {
        final result = await make().activate(server: 'https://xyz.supabase.co', code: '123');
        expect(result, isA<ActivationFailed>());
        expect(backend.activations, isEmpty);
        await expectNothingSaved();
      });

      test('a disabled scanner', () async {
        backend.activateStatus = 403;
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, activationMessage(ActivationFailure.disabled));
        await expectNothingSaved();
      });

      test('no connection', () async {
        backend.activateFailWith = const SocketException('no route');
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, activationMessage(ActivationFailure.network));
        await expectNothingSaved();
      });

      test('a server error', () async {
        backend.activateStatus = 500;
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, activationMessage(ActivationFailure.server));
        await expectNothingSaved();
      });

      test('the wrong address (it answers, but not like our server)', () async {
        backend.activateStatus = 400;
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, activationMessage(ActivationFailure.badResponse));
        await expectNothingSaved();
      });

      test('a server address that is not an address', () async {
        final result = await make().activate(server: 'not an address', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, badAddressMessage);
        expect(backend.activations, isEmpty);
        await expectNothingSaved();
      });

      test('a server that has no college keys set up', () async {
        backend.keySet = null;
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, noKeysMessage);
        await expectNothingSaved();
      });

      test('college keys that are damaged', () async {
        backend.keySet = {'v': 2, 'current': 1, 'keys': <Object?>[]};
        final result = await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, badKeysMessage);
        await expectNothingSaved();
      });

      test('a key set that does not hold its own current key', () async {
        backend.keySet = {'v': 1, 'current': 9, 'keys': <Object?>[]};
        expect((await make().activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD')), isA<ActivationFailed>());
        await expectNothingSaved();
      });

      test('the phone cannot store the token: the scanner stays not activated', () async {
        final result = await make(store: _BrokenIdentityStore()).activate(server: 'https://xyz.supabase.co', code: 'K7QM-29XD');
        expect((result as ActivationFailed).message, saveFailedMessage);
        expect(await identities.load(), isNull);
      });
    });

    test('plain http is refused unless development allows it', () async {
      final refused = await make().activate(server: 'http://127.0.0.1:8787', code: 'K7QM-29XD');
      expect((refused as ActivationFailed).message, badAddressMessage);
      expect(backend.activations, isEmpty);

      final allowed = await make(allowInsecure: true).activate(server: 'http://127.0.0.1:8787', code: 'K7QM-29XD');
      expect(allowed, isA<Activated>());
    });
  });
}

class _BrokenIdentityStore implements IdentityStore {
  @override
  Future<ScannerIdentity?> load() async => null;

  @override
  Future<void> save(ScannerIdentity identity) async => throw const FileSystemException('storage is full');

  @override
  Future<void> clear() async {}
}
