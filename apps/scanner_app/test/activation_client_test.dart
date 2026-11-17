import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scanner_app/src/activation_client.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

Map<String, Object?> _reply({Object? keyset = const {'v': 1, 'current': 2, 'keys': <Object?>[]}, Object? token = _token}) => {
      'scanner_id': 'SC-NEW',
      'name': 'New scanner',
      'gate': 'North gate',
      'token': token,
      'keyset': keyset,
      'revocation_list': null,
      'guards': <Object?>[],
      'server_time': 1793118000,
    };

http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('normalizeActivationCode', () {
    test('reads capitals, small letters, spaces and the hyphen alike', () {
      for (final typed in ['K7QM-29XD', 'k7qm-29xd', 'K7QM29XD', ' k7qm 29xd ', 'K7-QM-29-XD']) {
        expect(normalizeActivationCode(typed), 'K7QM29XD', reason: typed);
      }
    });

    test('refuses what cannot be a code: wrong length, or a letter the server never uses', () {
      for (final bad in ['', 'K7QM-29X', 'K7QM-29XDA', 'K7QM-29X0', 'K7QM-29XI', 'K7QM-29XO', 'K7QM-29X1', 'K7QM-29X!']) {
        expect(normalizeActivationCode(bad), isNull, reason: bad);
      }
    });
  });

  group('parseServerAddress', () {
    test('adds https to a bare host and drops a trailing slash', () {
      expect(parseServerAddress('xyz.supabase.co').toString(), 'https://xyz.supabase.co');
      expect(parseServerAddress('https://xyz.supabase.co/').toString(), 'https://xyz.supabase.co');
      expect(parseServerAddress('  https://xyz.supabase.co  ').toString(), 'https://xyz.supabase.co');
    });

    test('keeps a path, so a project behind a prefix still works', () {
      expect(parseServerAddress('https://example.org/api/').toString(), 'https://example.org/api');
    });

    test('refuses things that are not a server address', () {
      for (final bad in ['', '   ', 'not a url', 'https://', 'ftp://x.org', 'https://a.org/?x=1', 'https://a.org/#frag', 'https://user:pw@a.org']) {
        expect(parseServerAddress(bad), isNull, reason: bad);
      }
    });

    test('plain http only when development allows it', () {
      expect(parseServerAddress('http://127.0.0.1:8787'), isNull);
      expect(parseServerAddress('http://127.0.0.1:8787', allowInsecure: true).toString(), 'http://127.0.0.1:8787');
    });
  });

  group('ActivationClient', () {
    final base = Uri.parse('https://xyz.supabase.co');

    test('knows the two function addresses under the server', () {
      final client = ActivationClient(base, httpClient: MockClient((_) async => _json(_reply())));
      expect(client.activateUri.toString(), 'https://xyz.supabase.co/functions/v1/scanner-activate');
      expect(client.syncUri.toString(), 'https://xyz.supabase.co/functions/v1/scanner-sync');
      expect(ActivationClient(Uri.parse('https://example.org/api'), httpClient: MockClient((_) async => _json(_reply()))).syncUri.toString(), 'https://example.org/api/functions/v1/scanner-sync');
    });

    test('posts the code, tidied, as JSON, with no credentials', () async {
      late http.Request seen;
      final client = ActivationClient(base, httpClient: MockClient((r) async {
        seen = r;
        return _json(_reply());
      }));

      await client.activate(' k7qm 29xd ');

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://xyz.supabase.co/functions/v1/scanner-activate');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(seen.body), {'code': 'K7QM29XD'});
    });

    test('reads the scanner, its token and its keys from the reply', () async {
      final reply = await ActivationClient(base, httpClient: MockClient((_) async => _json(_reply()))).activate('K7QM-29XD');

      expect(reply.scannerId, 'SC-NEW');
      expect(reply.name, 'New scanner');
      expect(reply.gate, 'North gate');
      expect(reply.token, _token);
      expect(reply.keySet, {'v': 1, 'current': 2, 'keys': <Object?>[]});
      expect(reply.serverTimeS, 1793118000);
    });

    test('a reply with no key set is still a reply (the caller decides what that means)', () async {
      final reply = await ActivationClient(base, httpClient: MockClient((_) async => _json(_reply(keyset: null)))).activate('K7QM-29XD');
      expect(reply.keySet, isNull);
    });

    test('a code that cannot be one never reaches the network', () async {
      var calls = 0;
      final client = ActivationClient(base, httpClient: MockClient((_) async {
        calls++;
        return _json(_reply());
      }));

      await expectLater(client.activate('abc'), throwsA(isA<ActivationException>().having((e) => e.failure, 'failure', ActivationFailure.invalidCode)));
      expect(calls, 0);
    });

    Future<ActivationFailure> failureFor(MockClient mock) async {
      try {
        await ActivationClient(base, httpClient: mock, timeout: const Duration(milliseconds: 80)).activate('K7QM-29XD');
      } on ActivationException catch (e) {
        return e.failure;
      }
      fail('expected an ActivationException');
    }

    test('maps what the server says to a failure', () async {
      expect(await failureFor(MockClient((_) async => _json({'error': 'invalid_or_expired_code'}, 404))), ActivationFailure.invalidCode);
      expect(await failureFor(MockClient((_) async => _json({'error': 'scanner_disabled'}, 403))), ActivationFailure.disabled);
      expect(await failureFor(MockClient((_) async => _json({}, 500))), ActivationFailure.server);
      expect(await failureFor(MockClient((_) async => _json({}, 503))), ActivationFailure.server);
      expect(await failureFor(MockClient((_) async => _json({}, 429))), ActivationFailure.server);
      expect(await failureFor(MockClient((_) async => _json({}, 400))), ActivationFailure.badResponse);
      expect(await failureFor(MockClient((_) async => _json({}, 401))), ActivationFailure.badResponse);
    });

    test('no connection, and a server that never answers, are network failures', () async {
      expect(await failureFor(MockClient((_) async => throw const SocketException('no route'))), ActivationFailure.network);
      expect(await failureFor(MockClient((_) async => throw http.ClientException('closed'))), ActivationFailure.network);
      expect(await failureFor(MockClient((_) => Completer<http.Response>().future)), ActivationFailure.network);
    });

    for (final entry in {
      'not JSON': http.Response('hello', 200),
      'a JSON list': http.Response('[1]', 200),
      'no token': _json(_reply(token: null)),
      'a token that is too short to be real': _json(_reply(token: 'abc')),
      'no scanner id': _json({..._reply(), 'scanner_id': null}),
      'no gate': _json({..._reply(), 'gate': ''}),
    }.entries) {
      test('${entry.key} in a 200 reply is a bad response, not an activation', () async {
        expect(await failureFor(MockClient((_) async => entry.value)), ActivationFailure.badResponse);
      });
    }

    test('does not close a client it was handed', () async {
      var closed = false;
      final mock = _ClosingClient(MockClient((_) async => _json(_reply())), () => closed = true);
      final client = ActivationClient(base, httpClient: mock);
      await client.activate('K7QM-29XD');
      client.close();
      expect(closed, isFalse);
    });
  });
}

class _ClosingClient extends http.BaseClient {
  _ClosingClient(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}
