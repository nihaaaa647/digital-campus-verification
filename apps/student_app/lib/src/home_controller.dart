import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'demo_issuer.dart';
import 'keystore_signer.dart';
import 'pass_controller.dart';
import 'pass_store.dart';
import 'server_address.dart';
import 'session_store.dart';
import 'student_api.dart';

/// Which screen the student is on. It follows from what the phone holds and what the server says, so the
/// app can be killed at any point and open again on the right one.
enum Stage {
  /// Looking at what the phone holds and asking the server where the enrolment stands.
  starting,

  /// No login on this phone: email, then the 6-digit code.
  signedOut,

  /// Logged in, no enrolment (or a rejected one): phone number and photo.
  details,

  /// Sent, waiting for an admin.
  pending,

  /// Approved: getting the pass signed for this phone's key.
  activating,

  /// The pass, with its live QR.
  pass,

  /// The server could not be reached, or said something the app cannot act on. Offers a retry.
  offline,
}

int _systemNowS() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A pass this close to its end is renewed when the app opens, while there is still time to do it at leisure.
const Duration renewWithin = Duration(days: 14);

const int minPhotoBytes = 1000;
const int maxPhotoBytes = 1500000;

/// `+91 98765-43210` -> `+919876543210`; null if it cannot be a phone number. The server applies the same rule.
String? normalizePhone(String input) {
  final p = input.replaceAll(RegExp(r'[\s()-]'), '');
  return RegExp(r'^\+?\d{10,15}$').hasMatch(p) ? p : null;
}

/// The words for a failure, as a student should read them.
String describeFailure(ApiException e) => switch (e.failure) {
      ApiFailure.network => "Can't reach the college server. Check the connection and the server address.",
      ApiFailure.unauthorized => 'Your sign-in ended. Please sign in again.',
      ApiFailure.badEmail => "That doesn't look like an email address.",
      ApiFailure.notOnRoster => 'Use your college email: your roll number followed by @vnrvjiet.in.',
      ApiFailure.wait => 'Please wait ${e.retryAfterS ?? 30} seconds before asking for another code.',
      ApiFailure.wrongCode => 'That code is wrong or has expired.',
      ApiFailure.tooManyAttempts => 'Too many wrong tries. Go back and ask for a new code.',
      ApiFailure.badInput => switch (e.detail) {
          'bad_phone' => "That phone number doesn't look right.",
          'bad_profile' => 'Check your name, branch and year.',
          'bad_photo' => "That photo can't be used. Take another one.",
          'profile_invalid' => "Your details on the college roster don't fit on a pass. Ask the college office to fix them.",
          _ => "The college server didn't accept that (${e.detail}).",
        },
      ApiFailure.alreadyApproved => 'You are already approved.',
      ApiFailure.notApproved => e.detail == 'student_not_active' ? 'Your pass is paused. Please contact the college office.' : 'Your enrolment is not approved yet.',
      ApiFailure.server => 'The college server had a problem. Try again in a moment.',
      ApiFailure.badResponse => "That address doesn't look like the college server.",
    };

/// Everything the student does before and around the pass: sign in, enrol, wait, get the pass, sign out.
/// The screens only show [stage] and call these methods; every rule is here so it can be tested without a screen.
class HomeController extends ChangeNotifier {
  HomeController({
    required this.sessions,
    required this.passes,
    required this.signer,
    required this.apiFor,
    this.defaultServer,
    this.allowInsecure = false,
    this.allowDemo = false,
    int Function()? phoneNowS,
  }) : phoneNowS = phoneNowS ?? _systemNowS;

  final SessionStore sessions;
  final PassStore passes;
  final KeystoreSigner signer;

  /// Makes the client for a server address. Tests hand in one on a fake network.
  final StudentApi Function(Uri base) apiFor;

  /// The address to use until the student picks another (a build setting).
  final Uri? defaultServer;

  /// Accept `http://` server addresses (development).
  final bool allowInsecure;

  /// Debug builds: offer a pass made with the public test key, with no server.
  final bool allowDemo;

  final int Function() phoneNowS;

  Stage _stage = Stage.starting;
  PassController? _pass;
  PassProblem? _problem;
  Session? _session;
  StudentProfile? _student;
  Uri? _server;
  StudentApi? _api;
  String? _notice;
  String? _error;
  bool _busy = false;
  bool _checkFailed = false;
  bool _profileComplete = true;
  String? _codeSentTo;
  String? _devOtp;
  bool _disposed = false;

  Stage get stage => _stage;

  /// The live pass, when [stage] is [Stage.pass]. The pass screen owns it and disposes it.
  PassController? get pass => _pass;

  /// Why there is no pass on this phone, when there is none.
  PassProblem? get problem => _problem;
  StudentProfile? get student => _student;
  Uri? get server => _server;

  /// A line that explains how the student got here ("Your sign-in ended"), shown above the form.
  String? get notice => _notice;

  /// The last thing that went wrong in the current step.
  String? get error => _error;
  bool get busy => _busy;

  /// False until a student the roster did not list has given name, branch and year (read off the ID card).
  bool get profileComplete => _profileComplete;

  /// The last status check failed (pending screen): shown as a quiet note, not an error page.
  bool get checkFailed => _checkFailed;

  /// The email a code was sent to; null while the student is still entering the email.
  String? get codeSentTo => _codeSentTo;

  /// The code itself, when the server is in demo mode and shows it (there is no email service in the prototype).
  String? get devOtp => _devOtp;

  int get _now => phoneNowS();

  void _go(Stage stage) {
    _stage = stage;
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  StudentApi get _client {
    final base = _server;
    if (base == null) throw const ApiException(ApiFailure.badResponse, 'no server address');
    return _api ??= apiFor(base);
  }

  /// Reads what the phone holds and goes to the right screen.
  Future<void> start() async {
    _go(Stage.starting);
    final saved = await sessions.loadServer();
    _server = (saved == null ? null : parseServerAddress(saved, allowInsecure: allowInsecure)) ?? defaultServer;
    _session = await sessions.load();
    _student = _session?.student;

    var load = await openPass(passes, signer, phoneNowS: phoneNowS);
    final ready = load.controller;
    if (ready != null && _session != null && ready.credential.exp - ready.nowS < renewWithin.inSeconds) {
      ready.dispose(); // never started, so there is nothing to stop
      await _tryRenew();
      load = await openPass(passes, signer, phoneNowS: phoneNowS);
    }
    if (_disposed) {
      load.controller?.dispose();
      return;
    }
    if (load.controller != null) {
      _pass = load.controller;
      _problem = null;
      _go(Stage.pass);
      return;
    }
    _problem = load.problem;
    if (_session == null) {
      _go(Stage.signedOut);
    } else {
      await _routeFromServer(quiet: false);
    }
  }

  // --- signing in ---

  /// Asks the server to send a code to [email].
  Future<void> requestCode(String email) async {
    if (_busy) return;
    if (_server == null) {
      _error = 'Enter the college server address first.';
      _changed();
      return;
    }
    _busy = true;
    _error = null;
    _changed();
    try {
      final normalized = email.trim().toLowerCase();
      final sent = await _client.requestOtp(normalized);
      _codeSentTo = normalized;
      _devOtp = sent.devOtp;
      _notice = null;
    } on ApiException catch (e) {
      _error = describeFailure(e);
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Back to entering the email.
  void useDifferentEmail() {
    _codeSentTo = null;
    _devOtp = null;
    _error = null;
    _changed();
  }

  Future<void> verifyCode(String code) async {
    final email = _codeSentTo;
    if (_busy || email == null) return;
    _busy = true;
    _error = null;
    _changed();
    try {
      final signedIn = await _client.verifyOtp(email, code.replaceAll(RegExp(r'\s'), ''));
      _session = Session(token: signedIn.token, student: signedIn.student);
      await sessions.save(_session!);
      _student = signedIn.student;
      _codeSentTo = null;
      _devOtp = null;
      _notice = null;
      _busy = false;
      await _routeFromServer(quiet: false);
    } on ApiException catch (e) {
      _error = describeFailure(e);
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Changes the server the app talks to. Returns a message if [text] is not an address, otherwise null.
  Future<String?> setServer(String text) async {
    final uri = parseServerAddress(text, allowInsecure: allowInsecure);
    if (uri == null) {
      return allowInsecure ? "That doesn't look like a server address." : 'Use the https:// address of the college server.';
    }
    _api?.close();
    _api = null;
    _server = uri;
    await sessions.saveServer(uri.toString());
    _error = null;
    _changed();
    return null;
  }

  // --- enrolling ---

  /// Sends the phone number and photo for approval.
  ///
  /// While [profileComplete] is false the name, branch and year go too (the server needs them for the pass).
  Future<void> submitDetails({required String phone, required Uint8List photo, String? name, String? branch, int? year}) async {
    final session = _session;
    if (_busy || session == null) return;
    final normalized = normalizePhone(phone);
    if (normalized == null) {
      _error = describeFailure(const ApiException(ApiFailure.badInput, 'bad_phone'));
      _changed();
      return;
    }
    if (photo.length < minPhotoBytes || photo.length > maxPhotoBytes) {
      _error = describeFailure(const ApiException(ApiFailure.badInput, 'bad_photo'));
      _changed();
      return;
    }
    EnrolProfile? profile;
    if (!_profileComplete) {
      final n = (name ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      final b = (branch ?? '').trim().toUpperCase();
      if (n.isEmpty || utf8.encode(n).length > 64 || b.isEmpty || utf8.encode(b).length > 12 || year == null || year < 1 || year > 6) {
        _error = describeFailure(const ApiException(ApiFailure.badInput, 'bad_profile'));
        _changed();
        return;
      }
      profile = EnrolProfile(name: n, branch: b, year: year);
    }
    _busy = true;
    _error = null;
    _changed();
    try {
      final state = await _client.enrol(session.token, phone: normalized, photo: photo, profile: profile);
      _notice = null;
      _busy = false;
      if (state == EnrolmentState.approved) {
        await _activate();
      } else {
        _go(Stage.pending);
      }
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.unauthorized) {
        await _sessionEnded();
      } else if (e.failure == ApiFailure.alreadyApproved) {
        _busy = false;
        await _routeFromServer(quiet: false);
      } else {
        _error = describeFailure(e);
      }
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Asks the server where the enrolment stands. [quiet] keeps the current screen up while it asks (the
  /// pending screen does this every few seconds); a failed quiet check only sets [checkFailed].
  Future<void> refresh({bool quiet = true}) async {
    if (_busy || _session == null || _disposed) return;
    await _routeFromServer(quiet: quiet);
  }

  Future<void> _routeFromServer({required bool quiet}) async {
    final session = _session;
    if (session == null) return;
    if (!quiet) _go(Stage.starting);
    try {
      final info = await _client.enrolmentStatus(session.token);
      if (_disposed) return;
      _student = info.student;
      _profileComplete = info.profileComplete;
      _checkFailed = false;
      _error = null;
      switch (info.state) {
        case EnrolmentState.approved:
          await _activate();
        case EnrolmentState.pending || EnrolmentState.flagged:
          _go(Stage.pending);
        case EnrolmentState.rejected:
          _notice = 'The college did not accept your photo. Please take a new one.';
          _go(Stage.details);
        case EnrolmentState.none:
          _go(Stage.details);
      }
    } on ApiException catch (e) {
      await _failed(e, quiet: quiet);
    }
  }

  Future<void> _failed(ApiException e, {required bool quiet}) async {
    if (e.failure == ApiFailure.unauthorized) return _sessionEnded();
    if (quiet && _stage == Stage.pending) {
      _checkFailed = true;
      _changed();
      return;
    }
    _error = describeFailure(e);
    _go(Stage.offline);
  }

  Future<void> _sessionEnded() async {
    await sessions.clear();
    _session = null;
    _notice = _problem == PassProblem.expired ? 'Your pass has expired. Sign in to renew it.' : 'Your sign-in ended. Please sign in again.';
    _error = null;
    _go(Stage.signedOut);
  }

  // --- the pass ---

  /// Signs the pass for this phone's key and shows it.
  Future<void> _activate() async {
    final session = _session;
    if (session == null) return;
    _go(Stage.activating);
    try {
      final key = await signer.getOrCreateKey();
      final issued = await _client.issueCredential(session.token, key.publicKey);
      await passes.save(StoredPass(signedCredential: issued.signedCredential, serverOffsetS: issued.serverTimeS - _now));
      final load = await openPass(passes, signer, phoneNowS: phoneNowS);
      if (_disposed) {
        load.controller?.dispose();
        return;
      }
      if (load.controller == null) {
        _error = 'The pass was issued but this phone cannot open it (${load.problem?.name}).';
        _go(Stage.offline);
        return;
      }
      _pass = load.controller;
      _problem = null;
      _error = null;
      _go(Stage.pass);
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.notApproved && e.detail == 'not_approved') {
        _go(Stage.pending); // the college took the approval back
      } else {
        await _failed(e, quiet: false);
      }
    } on KeystoreException {
      _error = "The phone's key store did not answer. Restart the phone and open the app again.";
      _go(Stage.offline);
    }
  }

  /// Renews quietly, at startup, a pass that is close to its end. A failure changes nothing: the old pass
  /// keeps working until it expires.
  Future<void> _tryRenew() async {
    final session = _session;
    if (session == null) return;
    try {
      final key = await signer.existingKey();
      if (key == null) return;
      final issued = await _client.issueCredential(session.token, key.publicKey).timeout(const Duration(seconds: 6));
      await passes.save(StoredPass(signedCredential: issued.signedCredential, serverOffsetS: issued.serverTimeS - _now));
    } catch (_) {
      // Offline, session ended, paused: the current pass is still good.
    }
  }

  /// Retry after [Stage.offline].
  Future<void> retry() async {
    if (_session == null) return start();
    await _routeFromServer(quiet: false);
  }

  /// Removes the login, the pass and the phone's key. Another student can then use this phone.
  Future<void> signOut() async {
    final session = _session;
    if (session != null) {
      try {
        await _client.signOut(session.token).timeout(const Duration(seconds: 5));
      } catch (_) {
        // The phone forgets the login whether or not the server heard about it.
      }
    }
    await sessions.clear();
    await passes.clear();
    try {
      await signer.deleteKey();
    } catch (_) {
      // No key, or the key store is not answering: a new key is made at the next sign-in either way.
    }
    _session = null;
    _student = null;
    _pass = null;
    _problem = PassProblem.notActivated;
    _codeSentTo = null;
    _devOtp = null;
    _notice = null;
    _error = null;
    _go(Stage.signedOut);
  }

  // --- debug builds ---

  /// A pass made with the public test key, with no server and no login.
  Future<void> createDemoPass() async {
    if (!allowDemo) return;
    final key = await signer.getOrCreateKey();
    await passes.save(issueDemoPass(devicePublicKey: key.publicKey, nowS: _now));
    final load = await openPass(passes, signer, phoneNowS: phoneNowS);
    if (load.controller != null) {
      _pass = load.controller;
      _problem = null;
      _go(Stage.pass);
    } else {
      _problem = load.problem;
      _go(Stage.signedOut);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _api?.close();
    super.dispose();
  }
}
