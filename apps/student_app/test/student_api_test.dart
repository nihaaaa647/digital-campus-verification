import 'dart:async';
import 'dart:convert';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_app/src/server_address.dart';
import 'package:student_app/src/student_api.dart';

import 'support/fake_campus_server.dart';
import 'support/fake_keystore.dart';

StudentApi _api(Future<http.Response> Function(http.Request) handler, {Duration timeout = const Duration(seconds: 5)}) =>
    StudentApi(Uri.parse('http://127.0.0.1:8787'), httpClient: MockClient(handler), timeout: timeout);

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Future<ApiFailure> _failure(Future<Object?> Function() call) async {
  try {
    await call();
  } on ApiException catch (e) {
    return e.failure;
  }
  fail('expected an ApiException');
}

void main() {
  group('requestOtp', () {
    test('posts the email to the function and reads the demo code', () async {
      late http.Request seen;
      final sent = await _api((r) async {
        seen = r;
        return _json({'sent': true, 'dev_otp': '123456'});
      }).requestOtp('a@b.test');

      expect(seen.url.path, '/functions/v1/auth-request-otp');
      expect(seen.method, 'POST');
      expect(jsonDecode(seen.body), {'email': 'a@b.test'});
      expect(sent.devOtp, '123456');
    });

    test('no code in the reply means none was shown', () async {
      expect((await _api((r) async => _json({'sent': true})).requestOtp('a@b.test')).devOtp, isNull);
    });

    test('something that is not a code is not taken for one', () async {
      expect((await _api((r) async => _json({'sent': true, 'dev_otp': 'abc'})).requestOtp('a@b.test')).devOtp, isNull);
    });

    test('each status has its own failure', () async {
      for (final (status, expected) in [(400, ApiFailure.badEmail), (404, ApiFailure.notOnRoster), (429, ApiFailure.wait), (500, ApiFailure.server), (502, ApiFailure.server), (418, ApiFailure.badResponse)]) {
        expect(await _failure(() => _api((r) async => _json({'error': 'x'}, status)).requestOtp('a@b.test')), expected, reason: '$status');
      }
    });

    test('says how long to wait', () async {
      try {
        await _api((r) async => _json({'error': 'wait', 'retry_after_s': 17}, 429)).requestOtp('a@b.test');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.retryAfterS, 17);
      }
    });
  });

  group('verifyOtp', () {
    final good = {
      'access_token': 'x' * 43,
      'expires_in': 100,
      'student': {'name': 'Ravi Kumar', 'roll_number': '25071A0003', 'branch': 'CSE', 'year': 1, 'email': 'r@c.test'},
    };

    test('returns the token and who it is for', () async {
      final signedIn = await _api((r) async => _json(good)).verifyOtp('r@c.test', '123456');
      expect(signedIn.token, 'x' * 43);
      expect(signedIn.student.name, 'Ravi Kumar');
      expect(signedIn.student.year, 1);
    });

    test('401 is a wrong code, 429 is locked out', () async {
      expect(await _failure(() => _api((r) async => _json({'error': 'invalid_or_expired_otp'}, 401)).verifyOtp('r@c.test', '1')), ApiFailure.wrongCode);
      expect(await _failure(() => _api((r) async => _json({'error': 'too_many_attempts'}, 429)).verifyOtp('r@c.test', '1')), ApiFailure.tooManyAttempts);
    });

    test('a 200 that is not the contract is a bad response, never a half session', () async {
      for (final body in [<String, Object?>{}, {'access_token': 'short', 'student': good['student']}, {'access_token': 'x' * 43}, {'access_token': 'x' * 43, 'student': {'name': 'n'}}]) {
        expect(await _failure(() => _api((r) async => _json(body)).verifyOtp('r@c.test', '123456')), ApiFailure.badResponse, reason: '$body');
      }
    });
  });

  group('enrol', () {
    test('sends the phone and the photo as base64 with the token', () async {
      late http.Request seen;
      final photo = testPhoto();
      final state = await _api((r) async {
        seen = r;
        return _json({'status': 'pending', 'flags': <String>[]});
      }).enrol('tok-tok-tok-tok-tok', phone: '+919876543210', photo: photo);

      expect(state, EnrolmentState.pending);
      expect(seen.url.path, '/functions/v1/enrol');
      expect(seen.headers['Authorization'], 'Bearer tok-tok-tok-tok-tok');
      final body = jsonDecode(seen.body) as Map;
      expect(body['phone'], '+919876543210');
      expect(base64Decode(body['photo_base64'] as String), photo);
    });

    test('each status has its own failure, and the server\'s word is kept for bad input', () async {
      expect(await _failure(() => _api((r) async => _json({}, 401)).enrol('t', phone: '1', photo: Uint8List(1))), ApiFailure.unauthorized);
      expect(await _failure(() => _api((r) async => _json({}, 409)).enrol('t', phone: '1', photo: Uint8List(1))), ApiFailure.alreadyApproved);
      expect(await _failure(() => _api((r) async => _json({}, 413)).enrol('t', phone: '1', photo: Uint8List(1))), ApiFailure.badInput);
      try {
        await _api((r) async => _json({'error': 'bad_photo'}, 400)).enrol('t', phone: '1', photo: Uint8List(1));
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.failure, ApiFailure.badInput);
        expect(e.detail, 'bad_photo');
      }
    });

    test('a status it does not know is a bad response', () async {
      expect(await _failure(() => _api((r) async => _json({'status': 'maybe'})).enrol('t', phone: '1', photo: Uint8List(1))), ApiFailure.badResponse);
    });

    test('a slow upload is given three times the usual time', () async {
      final api = _api((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return _json({'status': 'pending'});
      }, timeout: const Duration(milliseconds: 100));
      expect(await api.enrol('t', phone: '1', photo: Uint8List(1)), EnrolmentState.pending);
      expect(await _failure(() => api.enrolmentStatus('t')), ApiFailure.network, reason: 'the ordinary calls keep the ordinary limit');
    });
  });

  group('enrolmentStatus', () {
    test('reads every state', () async {
      for (final state in EnrolmentState.values) {
        final info = await _api((r) async => _json({
              'status': state.name,
              'flags': <String>[],
              'student': {'name': 'n', 'roll_number': 'r', 'branch': 'b', 'year': 2, 'email': 'e@c.test'},
            })).enrolmentStatus('t');
        expect(info.state, state);
      }
    });

    test('is a GET with the token, and 401 means the session ended', () async {
      late http.Request seen;
      await _api((r) async {
        seen = r;
        return _json({'status': 'none', 'student': {'name': 'n', 'roll_number': 'r', 'branch': 'b', 'year': 2, 'email': 'e'}});
      }).enrolmentStatus('abc');
      expect(seen.method, 'GET');
      expect(seen.headers['Authorization'], 'Bearer abc');
      expect(await _failure(() => _api((r) async => _json({}, 401)).enrolmentStatus('t')), ApiFailure.unauthorized);
    });
  });

  group('issueCredential', () {
    test('sends the key as base64url and returns a pass the app can read', () async {
      final server = FakeCampusServer()..enrolments['ravi.kumar@college.test'] = 'approved';
      final api = server.apiFor(Uri.parse('http://127.0.0.1:8787'));
      await api.requestOtp('ravi.kumar@college.test');
      final signedIn = await api.verifyOtp('ravi.kumar@college.test', '123456');
      final key = publicKeyOf(devAPrivate);

      final issued = await api.issueCredential(signedIn.token, key);
      expect(issued.serverTimeS, 1790000000);
      final credential = decodeCredential(parseSignedCredential(issued.signedCredential)!.credentialBytes);
      expect(credential.dpk, key);
      expect(server.issuedTo, [toBase64Url(key)]);
    });

    test('403 carries the reason, 401 ends the session, 422 is bad input', () async {
      try {
        await _api((r) async => _json({'error': 'student_not_active'}, 403)).issueCredential('t', Uint8List(33));
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.failure, ApiFailure.notApproved);
        expect(e.detail, 'student_not_active');
      }
      expect(await _failure(() => _api((r) async => _json({}, 401)).issueCredential('t', Uint8List(33))), ApiFailure.unauthorized);
      expect(await _failure(() => _api((r) async => _json({'error': 'bad_device_key'}, 422)).issueCredential('t', Uint8List(33))), ApiFailure.badInput);
    });

    test('a pass that is not a pass is refused before it can be stored', () async {
      for (final body in [<String, Object?>{}, {'signed_credential': 'DK1.garbage', 'server_time': 1}, {'signed_credential': 'nope', 'server_time': 1}]) {
        expect(await _failure(() => _api((r) async => _json(body)).issueCredential('t', Uint8List(33))), ApiFailure.badResponse, reason: '$body');
      }
    });
  });

  group('signOut', () {
    test('succeeds on 200 and on 401 (already gone), fails otherwise', () async {
      await _api((r) async => _json({'ok': true})).signOut('t');
      await _api((r) async => _json({}, 401)).signOut('t');
      expect(await _failure(() => _api((r) async => _json({}, 500)).signOut('t')), ApiFailure.server);
    });
  });

  group('the network', () {
    test('no connection, a timeout and a socket error are all just "network"', () async {
      expect(await _failure(() => _api((r) async => throw http.ClientException('no route')).requestOtp('a@b.test')), ApiFailure.network);
      expect(await _failure(() => _api((r) async => throw TimeoutException('slow')).requestOtp('a@b.test')), ApiFailure.network);
      expect(await _failure(() => _api((r) async => throw const FormatException('weird')).requestOtp('a@b.test')), ApiFailure.network);
      expect(await _failure(() => _api((r) => Completer<http.Response>().future, timeout: const Duration(milliseconds: 50)).requestOtp('a@b.test')), ApiFailure.network);
    });

    test('a 200 from something else (a captive portal, the wrong address) is a bad response, not "code sent"', () async {
      expect(await _failure(() => _api((r) async => http.Response('<html>log in to the wifi</html>', 200)).requestOtp('a@b.test')), ApiFailure.badResponse);
      expect(await _failure(() => _api((r) async => _json({'hello': 'world'})).requestOtp('a@b.test')), ApiFailure.badResponse);
    });

    test('the server path prefix is kept (a project behind a proxy path)', () async {
      late Uri seen;
      final api = StudentApi(Uri.parse('https://campus.example.edu/api'), httpClient: MockClient((r) async {
        seen = r.url;
        return _json({'sent': true});
      }));
      await api.requestOtp('a@b.test');
      expect(seen.toString(), 'https://campus.example.edu/api/functions/v1/auth-request-otp');
    });
  });

  group('parseServerAddress', () {
    test('adds https, drops a trailing slash, keeps a path', () {
      expect(parseServerAddress('campus.example.edu'), Uri.parse('https://campus.example.edu'));
      expect(parseServerAddress(' https://campus.example.edu/ '), Uri.parse('https://campus.example.edu'));
      expect(parseServerAddress('https://x.supabase.co/api/'), Uri.parse('https://x.supabase.co/api'));
    });

    test('plain http only when development allows it', () {
      expect(parseServerAddress('http://192.168.1.5:8787'), isNull);
      expect(parseServerAddress('http://192.168.1.5:8787', allowInsecure: true), Uri.parse('http://192.168.1.5:8787'));
    });

    test('a bare local address is taken as http when development allows it', () {
      expect(parseServerAddress('192.168.1.5:8787', allowInsecure: true), Uri.parse('http://192.168.1.5:8787'));
      expect(parseServerAddress('localhost:8787', allowInsecure: true), Uri.parse('http://localhost:8787'));
      expect(parseServerAddress('192.168.1.5:8787'), Uri.parse('https://192.168.1.5:8787'), reason: 'a release build never guesses http');
    });

    test('rubbish is refused', () {
      for (final bad in ['', '   ', 'two words', 'ftp://x.edu', 'https://', 'https://x.edu?a=1', 'https://u:p@x.edu', 'https://x.edu#top']) {
        expect(parseServerAddress(bad, allowInsecure: true), isNull, reason: bad);
      }
    });
  });
}
