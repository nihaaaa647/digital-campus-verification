import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';
import 'package:http/http.dart' as http;

/// Why a call to the college server did not work. The words for each are in `onboarding_controller.dart`.
enum ApiFailure {
  /// No connection, a timeout, or nothing at that address.
  network,

  /// 401 on a call that needs a login: the session ended, or the server forgot it.
  unauthorized,

  /// 400 on the email.
  badEmail,

  /// 404 on the email: not on the college roster.
  notOnRoster,

  /// 429 on asking for a code again too soon; [ApiException.retryAfterS] says how long.
  wait,

  /// 401 on the code: wrong, expired or never asked for.
  wrongCode,

  /// 429 on the code: five wrong tries used.
  tooManyAttempts,

  /// 400 or 422 on what was sent (a phone number, a photo, a key); [ApiException.detail] has the server's word.
  badInput,

  /// 409: the enrolment is already approved.
  alreadyApproved,

  /// 403: no pass until an admin approves the enrolment, or the student is paused.
  notApproved,

  /// 5xx.
  server,

  /// The server answered, but not in the shape of the contract (usually the wrong address).
  badResponse,
}

class ApiException implements Exception {
  const ApiException(this.failure, [this.detail = '', this.retryAfterS]);

  final ApiFailure failure;
  final String detail;
  final int? retryAfterS;

  @override
  String toString() => 'ApiException(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

class StudentProfile {
  const StudentProfile({required this.name, required this.rollNumber, required this.branch, required this.year, required this.email});

  final String name;
  final String rollNumber;
  final String branch;
  final int year;
  final String email;

  Map<String, Object?> toJson() => {'name': name, 'roll_number': rollNumber, 'branch': branch, 'year': year, 'email': email};

  /// Null if [json] is not a profile.
  static StudentProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], roll = json['roll_number'], branch = json['branch'], year = json['year'], email = json['email'];
    if (name is! String || roll is! String || branch is! String || year is! int || email is! String) return null;
    return StudentProfile(name: name, rollNumber: roll, branch: branch, year: year, email: email);
  }
}

class OtpSent {
  const OtpSent({this.devOtp});

  /// The code itself, only when the server runs in demo mode (there is no email service in the prototype).
  final String? devOtp;
}

class SignedIn {
  const SignedIn({required this.token, required this.student});

  final String token;
  final StudentProfile student;
}

/// Where the student's enrolment stands, as `enrolment-status` reports it.
enum EnrolmentState {
  none,
  pending,
  flagged,
  approved,
  rejected;

  static EnrolmentState? parse(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

class EnrolmentInfo {
  const EnrolmentInfo({required this.state, required this.student, this.profileComplete = true});

  final EnrolmentState state;
  final StudentProfile student;

  /// False for a student who signed up with a roll-number email and has not yet given name, branch and year.
  final bool profileComplete;
}

/// Name, branch and year, sent once at enrolment by a student the roster did not list.
class EnrolProfile {
  const EnrolProfile({required this.name, required this.branch, required this.year});

  final String name;
  final String branch;
  final int year;
}

class IssuedPass {
  const IssuedPass({required this.signedCredential, required this.serverTimeS});

  final String signedCredential;

  /// The server's clock when it issued the pass, in unix seconds.
  final int serverTimeS;
}

/// The student-facing calls of the college server (supabase/functions/_shared/student_auth.ts, enrolment.ts,
/// issue_credential.ts). Every method either returns or throws an [ApiException]; nothing else escapes.
class StudentApi {
  StudentApi(this.serverBase, {http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// The project's base address, from `parseServerAddress`.
  final Uri serverBase;
  final Duration timeout;
  final http.Client _http;
  final bool _ownsClient;

  Uri _fn(String name) => serverBase.replace(path: '${serverBase.path}/functions/v1/$name');

  Future<OtpSent> requestOtp(String email) async {
    final r = await _call('auth-request-otp', body: {'email': email});
    switch (r.status) {
      case 200:
        // A page that merely answers 200 (a captive portal, the wrong server) is not "code sent".
        if (r.json['sent'] != true) throw const ApiException(ApiFailure.badResponse, 'not a code-sent reply');
        final dev = r.json['dev_otp'];
        return OtpSent(devOtp: dev is String && RegExp(r'^\d{6}$').hasMatch(dev) ? dev : null);
      case 400:
        throw const ApiException(ApiFailure.badEmail);
      case 404:
        throw const ApiException(ApiFailure.notOnRoster);
      case 429:
        final after = r.json['retry_after_s'];
        throw ApiException(ApiFailure.wait, '', after is int ? after : null);
    }
    throw _unexpected(r);
  }

  Future<SignedIn> verifyOtp(String email, String otp) async {
    final r = await _call('auth-verify-otp', body: {'email': email, 'otp': otp});
    switch (r.status) {
      case 200:
        final token = r.json['access_token'];
        final student = StudentProfile.fromJson(r.json['student']);
        if (token is! String || token.length < 16 || student == null) throw const ApiException(ApiFailure.badResponse, 'no token or student in the reply');
        return SignedIn(token: token, student: student);
      case 401:
        throw const ApiException(ApiFailure.wrongCode);
      case 429:
        throw const ApiException(ApiFailure.tooManyAttempts);
    }
    throw _unexpected(r);
  }

  /// Ends the session on the server. The caller forgets the token whatever happens here.
  Future<void> signOut(String token) async {
    final r = await _call('auth-sign-out', token: token);
    if (r.status != 200 && r.status != 401) throw _unexpected(r);
  }

  /// Sends the phone number and photo for approval. Returns the state the enrolment is now in.
  Future<EnrolmentState> enrol(String token, {required String phone, required Uint8List photo, EnrolProfile? profile}) async {
    final r = await _call(
      'enrol',
      token: token,
      body: {
        'phone': phone,
        'photo_base64': base64Encode(photo),
        if (profile != null) ...{'name': profile.name, 'branch': profile.branch, 'year': profile.year},
      },
      timeout: timeout * 3,
    );
    switch (r.status) {
      case 200:
        return EnrolmentState.parse(r.json['status']) ?? (throw const ApiException(ApiFailure.badResponse, 'unknown status'));
      case 400:
        throw ApiException(ApiFailure.badInput, '${r.json['error']}');
      case 401:
        throw const ApiException(ApiFailure.unauthorized);
      case 409:
        throw const ApiException(ApiFailure.alreadyApproved);
      case 413:
        throw const ApiException(ApiFailure.badInput, 'bad_photo');
    }
    throw _unexpected(r);
  }

  Future<EnrolmentInfo> enrolmentStatus(String token) async {
    final r = await _call('enrolment-status', method: 'GET', token: token);
    switch (r.status) {
      case 200:
        final state = EnrolmentState.parse(r.json['status']);
        final student = StudentProfile.fromJson(r.json['student']);
        if (state == null || student == null) throw const ApiException(ApiFailure.badResponse, 'status or student missing');
        final raw = r.json['student'];
        return EnrolmentInfo(state: state, student: student, profileComplete: raw is Map && raw['profile_complete'] != false);
      case 401:
        throw const ApiException(ApiFailure.unauthorized);
    }
    throw _unexpected(r);
  }

  /// Asks for the college-signed pass for [devicePublicKey] (the 33-byte compressed key from the Keystore).
  Future<IssuedPass> issueCredential(String token, Uint8List devicePublicKey) async {
    final r = await _call('issue-credential', token: token, body: {'device_public_key': toBase64Url(devicePublicKey)});
    switch (r.status) {
      case 200:
        final signed = r.json['signed_credential'];
        final serverTime = r.json['server_time'];
        if (signed is! String || parseSignedCredential(signed) == null || serverTime is! int) {
          throw const ApiException(ApiFailure.badResponse, 'no usable credential in the reply');
        }
        return IssuedPass(signedCredential: signed, serverTimeS: serverTime);
      case 401:
        throw const ApiException(ApiFailure.unauthorized);
      case 403:
        throw ApiException(ApiFailure.notApproved, '${r.json['error']}');
      case 422:
        throw ApiException(ApiFailure.badInput, '${r.json['error']}');
    }
    throw _unexpected(r);
  }

  Future<_Reply> _call(String function, {String method = 'POST', String? token, Map<String, Object?>? body, Duration? timeout}) async {
    final request = http.Request(method, _fn(function));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout ?? this.timeout));
    } on TimeoutException {
      throw const ApiException(ApiFailure.network, 'timed out');
    } on http.ClientException catch (e) {
      throw ApiException(ApiFailure.network, e.message);
    } on Exception catch (e) {
      throw ApiException(ApiFailure.network, e.toString());
    }
    Map<String, Object?> json = const {};
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      // A reply that is not JSON has an empty body for our purposes; the status still says what happened.
    }
    return _Reply(response.statusCode, json);
  }

  ApiException _unexpected(_Reply r) =>
      r.status >= 500 || r.status == 429 ? ApiException(ApiFailure.server, 'HTTP ${r.status}') : ApiException(ApiFailure.badResponse, 'HTTP ${r.status}');

  /// Closes the connection if this client made it; a client passed in stays open for its owner.
  void close() {
    if (_ownsClient) _http.close();
  }
}

class _Reply {
  const _Reply(this.status, this.json);

  final int status;
  final Map<String, Object?> json;
}
