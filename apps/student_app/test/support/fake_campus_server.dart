import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_app/src/id_card.dart';
import 'package:student_app/src/photo_source.dart';
import 'package:student_app/src/student_api.dart';

/// The college test key kv 1 (spec/test-vectors/v1.json): signs the passes this fake issues, and
/// `collegePublicKv1` in fake_keystore.dart is the half a scanner trusts.
final Uint8List _collegePrivateKv1 = hexToBytes('25d088b1661ba51e91af13d9eec1309cd3397e9a0181e0311c285fdaff68c13b');

class FakeStudent {
  const FakeStudent(this.id, this.name, this.roll, this.branch, this.year, this.email);

  final int id;
  final String name;
  final String roll;
  final String branch;
  final int year;
  final String email;
}

/// Stands in for the college server on a fake network, with the same URLs, status codes and bodies as
/// supabase/functions (student_auth.ts, enrolment.ts, issue_credential.ts) so [StudentApi] and the app run
/// unchanged on top of it. The real server is exercised by `student_server_integration_test.dart`.
class FakeCampusServer {
  FakeCampusServer({this.nowS = 1790000000});

  int nowS;
  final roster = <String, FakeStudent>{
    'ravi.kumar@college.test': const FakeStudent(3, 'Ravi Kumar', '25071A0003', 'CSE', 1, 'ravi.kumar@college.test'),
    'sravya@college.test': const FakeStudent(5, 'Śrāvya Ñandini', 'ADM26-00317', 'ECE', 1, 'sravya@college.test'),
  };

  /// When true, a new enrolment is approved on the spot (what the real server does). The older tests leave it
  /// off to exercise the waiting path, which the real server still uses after an admin rejects an enrolment.
  bool autoApprove = false;

  /// Students signed up by a roll-number email that the roster did not list, and who have not yet given a profile.
  final _incomplete = <String>{};
  final _signedUp = <String, FakeStudent>{};
  Map<String, Object?>? lastProfile;

  FakeStudent? _student(String email) => roster[email] ?? _signedUp[email];

  /// Whether the next code request is answered with the code in the body (demo mode).
  bool exposeOtp = true;
  String nextOtp = '123456';

  /// While true every call fails as if the phone had no connection.
  bool offline = false;

  /// While set, this function answers with this status and an empty body.
  final failing = <String, int>{};

  /// Runs at the start of `issue-credential`, before it looks at the enrolment.
  void Function()? beforeIssue;

  final _otps = <String, String>{};
  final _wrongTries = <String, int>{};
  final sessions = <String, String>{}; // token -> email
  final enrolments = <String, String>{}; // email -> pending | approved | rejected | flagged
  final phones = <String, String>{};
  final photos = <String, Uint8List>{};
  final issuedTo = <String>[]; // device public keys (base64url), in order
  final calls = <String>[];
  var _tokens = 0;
  int lifetimeS = 180 * 86400;

  late final http.Client client = MockClient(_handle);

  StudentApi apiFor(Uri base) => StudentApi(base, httpClient: client);

  void approve(String email) => enrolments[email] = 'approved';
  void reject(String email) => enrolments[email] = 'rejected';

  /// Ends every login, as when the server's sessions have expired.
  void endAllSessions() => sessions.clear();

  http.Response _json(Object body, [int status = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json; charset=utf-8'});

  Future<http.Response> _handle(http.Request r) async {
    if (offline) throw http.ClientException('no connection', r.url);
    final fn = r.url.pathSegments.last;
    calls.add(fn);
    final forced = failing[fn];
    if (forced != null) return http.Response('', forced);
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    final token = RegExp(r'^Bearer (\S+)$').firstMatch(r.headers['Authorization'] ?? '')?.group(1);
    final email = token == null ? null : sessions[token];

    switch (fn) {
      case 'auth-request-otp':
        final e = (body['email'] as String?)?.trim().toLowerCase() ?? '';
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(e)) return _json({'error': 'bad_email'}, 400);
        if (!roster.containsKey(e) && !RegExp(r'^(\d{5}[a-z][0-9a-z]{4}|adm\d{2}-\d{5})@vnrvjiet\.in$').hasMatch(e)) return _json({'error': 'not_on_roster'}, 404);
        _otps[e] = nextOtp;
        _wrongTries[e] = 0;
        return _json(exposeOtp ? {'sent': true, 'dev_otp': nextOtp} : {'sent': true});
      case 'auth-verify-otp':
        final e = body['email'] as String? ?? '';
        final tries = (_wrongTries[e] ?? 0);
        if (tries >= 5) return _json({'error': 'too_many_attempts'}, 429);
        if (_otps[e] == null || _otps[e] != body['otp']) {
          _wrongTries[e] = tries + 1;
          return _json({'error': 'invalid_or_expired_otp'}, 401);
        }
        _otps.remove(e);
        var s = _student(e);
        if (s == null) {
          final roll = e.split('@').first.toUpperCase();
          s = _signedUp[e] = FakeStudent(100 + _signedUp.length, roll, roll, '-', 1, e);
          _incomplete.add(e);
        }
        final t = 'token-${++_tokens}-${'x' * 30}';
        sessions[t] = e;
        return _json({
          'access_token': t,
          'expires_in': 2592000,
          'student': {'name': s.name, 'roll_number': s.roll, 'branch': s.branch, 'year': s.year, 'email': e, 'profile_complete': !_incomplete.contains(e)},
        });
      case 'auth-sign-out':
        if (email == null) return _json({'error': 'unauthorized'}, 401);
        sessions.remove(token);
        return _json({'ok': true});
      case 'enrol':
        if (email == null) return _json({'error': 'unauthorized'}, 401);
        if (enrolments[email] == 'approved') return _json({'error': 'already_approved'}, 409);
        final phone = (body['phone'] as String?) ?? '';
        if (!RegExp(r'^\+?\d{10,15}$').hasMatch(phone)) return _json({'error': 'bad_phone'}, 400);
        final photo = base64Decode((body['photo_base64'] as String?) ?? '');
        if (photo.length < 1000) return _json({'error': 'bad_photo'}, 400);
        if (_incomplete.contains(email)) {
          final name = (body['name'] as String?)?.trim() ?? '';
          final branch = (body['branch'] as String?)?.trim() ?? '';
          final year = body['year'];
          if (name.isEmpty || branch.isEmpty || branch.length > 12 || year is! int || year < 1 || year > 6) return _json({'error': 'bad_profile'}, 400);
          final old = _signedUp[email]!;
          _signedUp[email] = FakeStudent(old.id, name, old.roll, branch.toUpperCase(), year, email);
          _incomplete.remove(email);
          lastProfile = {'name': name, 'branch': branch, 'year': year};
        }
        phones[email] = phone;
        photos[email] = Uint8List.fromList(photo);
        final status = autoApprove && enrolments[email] != 'rejected' ? 'approved' : 'pending';
        enrolments[email] = status;
        return _json({'status': status, 'flags': <String>[]});
      case 'enrolment-status':
        if (email == null) return _json({'error': 'unauthorized'}, 401);
        final s = _student(email)!;
        return _json({
          'status': enrolments[email] ?? 'none',
          'flags': <String>[],
          'student': {'name': s.name, 'roll_number': s.roll, 'branch': s.branch, 'year': s.year, 'email': email, 'profile_complete': !_incomplete.contains(email)},
        });
      case 'issue-credential':
        beforeIssue?.call();
        if (email == null) return _json({'error': 'unauthorized'}, 401);
        final key = fromBase64Url(body['device_public_key'] as String? ?? '');
        if (key == null || key.length != 33) return _json({'error': 'bad_device_key'}, 422);
        if (enrolments[email] != 'approved') return _json({'error': 'not_approved', 'status': enrolments[email] ?? 'none'}, 403);
        final s = _student(email)!;
        issuedTo.add(toBase64Url(key));
        final credential = Credential(
          v: formatVersion,
          kv: 1,
          sid: s.id,
          roll: s.roll,
          name: s.name,
          branch: s.branch,
          year: s.year,
          pass: PassType.student.code,
          photo: Uint8List(16),
          dpk: key,
          iat: nowS,
          exp: nowS + lifetimeS,
        );
        final bytes = encodeCredential(credential);
        final sig = signEcdsa(_collegePrivateKv1, collegeSigningInput(bytes));
        return _json({'signed_credential': encodeSignedCredential(bytes, sig), 'server_time': nowS, 'key_version': 1});
    }
    return _json({'error': 'not_found'}, 404);
  }
}

/// A valid PNG big enough to pass the server's size check (a few KB of noise), built here so the tests need no
/// image files.
Uint8List testPhoto({int seed = 1}) {
  const side = 40;
  final raw = BytesBuilder();
  var x = seed * 7919;
  for (var y = 0; y < side; y++) {
    raw.addByte(0); // filter: none
    for (var i = 0; i < side * 3; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      raw.addByte((x >> 16) & 0xff);
    }
  }
  final png = BytesBuilder()..add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final typed = [...type.codeUnits, ...data];
    png.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    png.add(typed);
    png.add((ByteData(4)..setUint32(0, _crc32(typed))).buffer.asUint8List());
  }

  chunk('IHDR', (ByteData(13)..setUint32(0, side)..setUint32(4, side)..setUint8(8, 8)..setUint8(9, 2)).buffer.asUint8List());
  chunk('IDAT', ZLibCodec(level: 0).encode(raw.toBytes()));
  chunk('IEND', const []);
  return png.toBytes();
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

class FakePhotos implements PhotoSource {
  FakePhotos({Uint8List? photo}) : photo = photo ?? testPhoto();

  Uint8List? photo;
  PhotoException? failWith;
  final asked = <PhotoOrigin>[];

  @override
  Future<Uint8List?> take(PhotoOrigin origin) async {
    asked.add(origin);
    final failure = failWith;
    if (failure != null) throw failure;
    return photo;
  }
}


/// Stands in for the camera and the text recogniser: returns what a card would give.
class FakeCards implements CardReader {
  FakeCards([this.card]);

  CardDetails? card;
  PhotoException? failWith;
  final asked = <PhotoOrigin>[];

  @override
  Future<CardDetails?> read(PhotoOrigin origin) async {
    asked.add(origin);
    final failure = failWith;
    if (failure != null) throw failure;
    return card;
  }
}
