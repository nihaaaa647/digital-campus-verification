import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/src/home_controller.dart';
import 'package:student_app/src/keystore_signer.dart';
import 'package:student_app/src/pass_controller.dart';
import 'package:student_app/src/pass_store.dart';
import 'package:student_app/src/session_store.dart';

import 'support/fake_campus_server.dart';
import 'support/fake_keystore.dart';

const int _t0 = 1790000000;
const String _ravi = 'ravi.kumar@college.test';
final Uri _server = Uri.parse('http://127.0.0.1:8787');

/// Everything the app touches, on fakes: the college server, the phone's key store, and the two stores on disk.
class Rig {
  Rig({Uri? defaultServer, this.allowDemo = false, this.allowInsecure = true, FakeKeystore? keystore})
      : defaultServer = defaultServer ?? _server,
        keystore = keystore ?? FakeKeystore(hasKey: false) {
    this.keystore.install();
  }

  final Uri defaultServer;
  final bool allowDemo;
  final bool allowInsecure;
  final FakeCampusServer server = FakeCampusServer(nowS: _t0);
  final FakeKeystore keystore;
  final MemoryPassStore passes = MemoryPassStore();
  final MemorySessionStore sessions = MemorySessionStore();
  int phoneNow = _t0;

  /// The phone's clock and the server's move together.
  void advanceDays(int days) {
    phoneNow += days * 86400;
    server.nowS = phoneNow;
  }

  HomeController newHome() => HomeController(
        sessions: sessions,
        passes: passes,
        signer: KeystoreSigner(),
        apiFor: server.apiFor,
        defaultServer: defaultServer,
        allowInsecure: allowInsecure,
        allowDemo: allowDemo,
        phoneNowS: () => phoneNow,
      );

  /// The app opened (again) on this phone.
  Future<HomeController> open() async {
    final home = newHome();
    addTearDown(() {
      home.pass?.dispose();
      home.dispose();
    });
    await home.start();
    return home;
  }
}

/// Sign in, enrol, get approved, and end up with a pass.
Future<HomeController> onboard(Rig rig, {String email = _ravi}) async {
  final home = await rig.open();
  await home.requestCode(email);
  await home.verifyCode(home.devOtp!);
  await home.submitDetails(phone: '+91 98765 43210', photo: testPhoto());
  rig.server.approve(email);
  await home.refresh();
  expect(home.stage, Stage.pass);
  return home;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('signing in', () {
    test('a phone with nothing on it starts at the sign-in page', () async {
      final home = await Rig().open();
      expect(home.stage, Stage.signedOut);
      expect(home.problem, PassProblem.notActivated);
      expect(home.server, _server);
    });

    test('the code goes to the roster email, in the form the server wants, and signing in finds no enrolment yet', () async {
      final rig = Rig();
      final home = await rig.open();

      await home.requestCode('  Ravi.Kumar@College.test ');
      expect(home.codeSentTo, _ravi);
      expect(home.devOtp, '123456');

      await home.verifyCode(' 123 456 ');
      expect(home.stage, Stage.details);
      expect(home.student?.name, 'Ravi Kumar');
      expect(home.codeSentTo, isNull);
      expect(home.devOtp, isNull);
      expect((await rig.sessions.load())?.student.rollNumber, '25071A0003', reason: 'the login is saved so the app can be closed');
    });

    test('an email that is not on the roster is told so, and nothing is sent', () async {
      final home = await Rig().open();
      await home.requestCode('stranger@college.test');
      expect(home.error, contains('@vnrvjiet.in'));
      expect(home.codeSentTo, isNull);
    });

    test('not an email at all', () async {
      final home = await Rig().open();
      await home.requestCode('ravi');
      expect(home.error, contains("doesn't look like an email"));
    });

    test('a wrong code keeps the page, and the right one then works', () async {
      final home = await Rig().open();
      await home.requestCode(_ravi);
      await home.verifyCode('000000');
      expect(home.error, contains('wrong or has expired'));
      expect(home.codeSentTo, _ravi);
      expect(home.stage, Stage.signedOut);

      await home.verifyCode('123456');
      expect(home.stage, Stage.details);
      expect(home.error, isNull);
    });

    test('five wrong tries lock the code', () async {
      final home = await Rig().open();
      await home.requestCode(_ravi);
      for (var i = 0; i < 5; i++) {
        await home.verifyCode('000000');
      }
      await home.verifyCode('123456');
      expect(home.error, contains('Too many wrong tries'));
      expect(home.stage, Stage.signedOut);
    });

    test('a server that does not show codes gives none to the app', () async {
      final rig = Rig();
      rig.server.exposeOtp = false;
      final home = await rig.open();
      await home.requestCode(_ravi);
      expect(home.codeSentTo, _ravi);
      expect(home.devOtp, isNull);
    });

    test('asking again too soon is told to wait', () async {
      final rig = Rig();
      rig.server.failing['auth-request-otp'] = 429;
      final home = await rig.open();
      await home.requestCode(_ravi);
      expect(home.error, contains('wait'));
    });

    test('no connection is not blamed on the student', () async {
      final rig = Rig();
      final home = await rig.open();
      rig.server.offline = true;
      await home.requestCode(_ravi);
      expect(home.error, contains("Can't reach the college server"));
      expect(home.busy, isFalse);
    });

    test('without a server address it asks for one instead of failing', () async {
      final rig = Rig();
      final home = HomeController(sessions: rig.sessions, passes: rig.passes, signer: KeystoreSigner(), apiFor: rig.server.apiFor);
      addTearDown(home.dispose);
      await home.start();
      await home.requestCode(_ravi);
      expect(home.error, contains('server address'));
      expect(rig.server.calls, isEmpty);
    });

    test('using a different email goes back a step', () async {
      final home = await Rig().open();
      await home.requestCode(_ravi);
      home.useDifferentEmail();
      expect(home.codeSentTo, isNull);
      expect(home.devOtp, isNull);
    });
  });

  group('the server address', () {
    test('a typed address is saved, and used the next time the app opens', () async {
      final rig = Rig(defaultServer: Uri.parse('http://127.0.0.1:1'));
      final home = await rig.open();
      expect(await home.setServer('192.168.1.20:8787'), isNull);
      expect(home.server, Uri.parse('http://192.168.1.20:8787'));

      final again = await rig.open();
      expect(again.server, Uri.parse('http://192.168.1.20:8787'));
    });

    test('nonsense is refused and the old address stays', () async {
      final home = await Rig().open();
      expect(await home.setServer('not a server'), isNotNull);
      expect(home.server, _server);
    });

    test('a release build takes https only', () async {
      final rig = Rig(allowInsecure: false);
      final home = await rig.open();
      expect(await home.setServer('http://192.168.1.20:8787'), contains('https://'));
      expect(await home.setServer('campus.example.edu'), isNull);
      expect(home.server, Uri.parse('https://campus.example.edu'));
    });
  });

  group('enrolling', () {
    Future<(Rig, HomeController)> signedIn() async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      return (rig, home);
    }

    test('phone and photo go up and the student waits', () async {
      final (rig, home) = await signedIn();
      final photo = testPhoto();
      await home.submitDetails(phone: '+91 98765-43210', photo: photo);

      expect(home.stage, Stage.pending);
      expect(rig.server.phones[_ravi], '+919876543210');
      expect(rig.server.photos[_ravi], photo);
      expect(rig.server.enrolments[_ravi], 'pending');
    });

    test('a number that cannot be one never reaches the server', () async {
      final (rig, home) = await signedIn();
      await home.submitDetails(phone: '12345', photo: testPhoto());
      expect(home.error, contains('phone number'));
      expect(home.stage, Stage.details);
      expect(rig.server.calls, isNot(contains('enrol')));
    });

    test('a photo that is too small or too large never reaches the server', () async {
      final (rig, home) = await signedIn();
      await home.submitDetails(phone: '9876543210', photo: Uint8List.fromList([1, 2, 3]));
      expect(home.error, contains("photo can't be used"));
      await home.submitDetails(phone: '9876543210', photo: Uint8List(maxPhotoBytes + 1));
      expect(home.error, contains("photo can't be used"));
      expect(rig.server.calls, isNot(contains('enrol')));
    });

    test('the server refusing the photo is explained and the form stays', () async {
      final (rig, home) = await signedIn();
      rig.server.failing['enrol'] = 400;
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      expect(home.stage, Stage.details);
      expect(home.error, isNotNull);
      expect(home.busy, isFalse);
    });

    test('a rejected enrolment goes back to the form with the reason, and can be sent again', () async {
      final (rig, home) = await signedIn();
      await home.submitDetails(phone: '9876543210', photo: testPhoto(seed: 1));
      rig.server.reject(_ravi);
      await home.refresh();

      expect(home.stage, Stage.details);
      expect(home.notice, contains('did not accept your photo'));

      await home.submitDetails(phone: '9876543210', photo: testPhoto(seed: 2));
      expect(home.stage, Stage.pending);
      expect(home.notice, isNull);
      expect(rig.server.photos[_ravi], testPhoto(seed: 2));
    });

    test('while a second tap is in flight a first send is not repeated', () async {
      final (rig, home) = await signedIn();
      final first = home.submitDetails(phone: '9876543210', photo: testPhoto());
      final second = home.submitDetails(phone: '9876543210', photo: testPhoto());
      await Future.wait([first, second]);
      expect(rig.server.calls.where((c) => c == 'enrol'), hasLength(1));
    });
  });

  group('waiting, then the pass', () {
    test('approval turns into a pass bound to this phone\'s key', () async {
      final rig = Rig();
      final home = await onboard(rig);

      final stored = await rig.passes.load();
      final credential = decodeCredential(parseSignedCredential(stored!.signedCredential)!.credentialBytes);
      expect(credential.name, 'Ravi Kumar');
      expect(credential.roll, '25071A0003');
      expect(credential.dpk, rig.keystore.publicKey, reason: "the credential names the key in this phone's Keystore");
      expect(rig.server.issuedTo, [toBase64Url(rig.keystore.publicKey)]);
      expect(home.problem, isNull);
      expect(stored.serverOffsetS, 0);
    });

    test('the phone notes how far its clock is from the server\'s', () async {
      final rig = Rig();
      rig.server.nowS = _t0 + 42; // the phone is 42 s behind
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);
      await home.refresh();
      expect((await rig.passes.load())!.serverOffsetS, 42);
    });

    test('still pending is still pending', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      await home.refresh();
      await home.refresh();
      expect(home.stage, Stage.pending);
      expect(rig.server.calls.where((c) => c == 'issue-credential'), isEmpty);
    });

    test('a failed check while waiting is a quiet note, not an error page', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());

      rig.server.offline = true;
      await home.refresh();
      expect(home.stage, Stage.pending);
      expect(home.checkFailed, isTrue);

      rig.server.offline = false;
      rig.server.approve(_ravi);
      await home.refresh();
      expect(home.checkFailed, isFalse);
      expect(home.stage, Stage.pass);
    });

    test('flagged for review looks the same as pending to the student', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.enrolments[_ravi] = 'flagged';
      await home.refresh();
      expect(home.stage, Stage.pending);
    });

    test('approval taken back while the pass is being fetched returns to waiting', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);
      // The status check sees "approved"; by the time the pass is asked for, the college has taken it back.
      rig.server.beforeIssue = () => rig.server.enrolments[_ravi] = 'pending';
      await home.refresh();

      expect(home.stage, Stage.pending);
      expect(await rig.passes.load(), isNull);
    });

    test('a refusal with no reason is a failure with a retry, not a silent wait', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);
      rig.server.failing['issue-credential'] = 403;
      await home.refresh();

      expect(home.stage, Stage.offline);
      expect(home.error, isNotNull);
    });

    test('a key store that does not answer is explained, and retry works once it does', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);
      rig.keystore.failWith = PlatformException(code: 'keystore_error', message: 'dead');
      await home.refresh();
      expect(home.stage, Stage.offline);
      expect(home.error, contains('key store'));

      rig.keystore.failWith = null;
      await home.retry();
      expect(home.stage, Stage.pass);
    });

    test('the server being down at the moment of approval can be retried', () async {
      final rig = Rig();
      final home = await rig.open();
      await home.requestCode(_ravi);
      await home.verifyCode('123456');
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);
      rig.server.failing['issue-credential'] = 503;
      await home.refresh();
      expect(home.stage, Stage.offline);
      expect(home.error, contains('problem'));

      rig.server.failing.clear();
      await home.retry();
      expect(home.stage, Stage.pass);
    });
  });

  group('opening the app again', () {
    test('with a pass stored, the pass opens at once, even with no connection', () async {
      final rig = Rig();
      await onboard(rig);
      rig.server.calls.clear();
      rig.server.offline = true;

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      expect(rig.server.calls, isEmpty);
    });

    test('while waiting, it opens on the waiting page', () async {
      final rig = Rig();
      final first = await rig.open();
      await first.requestCode(_ravi);
      await first.verifyCode('123456');
      await first.submitDetails(phone: '9876543210', photo: testPhoto());

      final home = await rig.open();
      expect(home.stage, Stage.pending);
      expect(home.student?.name, 'Ravi Kumar');
    });

    test('signed in but never enrolled opens on the form', () async {
      final rig = Rig();
      final first = await rig.open();
      await first.requestCode(_ravi);
      await first.verifyCode('123456');

      expect((await rig.open()).stage, Stage.details);
    });

    test('approved while the app was closed: the pass appears without signing in again', () async {
      final rig = Rig();
      final first = await rig.open();
      await first.requestCode(_ravi);
      await first.verifyCode('123456');
      await first.submitDetails(phone: '9876543210', photo: testPhoto());
      rig.server.approve(_ravi);

      final home = await rig.open();
      expect(home.stage, Stage.pass);
    });

    test('a login the server has forgotten sends the student back to sign in, with a reason', () async {
      final rig = Rig();
      final first = await rig.open();
      await first.requestCode(_ravi);
      await first.verifyCode('123456');
      rig.server.endAllSessions();

      final home = await rig.open();
      expect(home.stage, Stage.signedOut);
      expect(home.notice, contains('sign-in ended'));
      expect(await rig.sessions.load(), isNull);
    });

    test('with a login but no connection and no pass, it offers a retry, and the retry works', () async {
      final rig = Rig();
      final first = await rig.open();
      await first.requestCode(_ravi);
      await first.verifyCode('123456');
      rig.server.offline = true;

      final home = await rig.open();
      expect(home.stage, Stage.offline);
      expect(home.error, contains("Can't reach"));

      rig.server.offline = false;
      await home.retry();
      expect(home.stage, Stage.details);
    });

    test('a pass issued to another key is replaced by one for this phone\'s key', () async {
      final rig = Rig();
      await onboard(rig);
      rig.keystore.privateKey = devBPrivate; // the Keystore now holds a different key than the pass names

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      final credential = home.pass!.credential;
      expect(credential.dpk, publicKeyOf(devBPrivate));
      expect(rig.server.issuedTo, hasLength(2));
    });

    test('a pass whose key is gone and whose login is gone asks for sign-in', () async {
      final rig = Rig();
      await onboard(rig);
      rig.keystore.hasKey = false;
      await rig.sessions.clear();

      final home = await rig.open();
      expect(home.stage, Stage.signedOut);
      expect(home.problem, PassProblem.deviceKeyMissing);
    });
  });

  group('expiry and renewal', () {
    test('a pass close to its end is renewed when the app opens, for the same key', () async {
      final rig = Rig();
      await onboard(rig);
      final firstExp = decodeCredential(parseSignedCredential((await rig.passes.load())!.signedCredential)!.credentialBytes).exp;
      rig.advanceDays(170); // 10 days left of 180

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      expect(home.pass!.credential.exp, greaterThan(firstExp));
      expect(home.pass!.credential.exp, rig.phoneNow + 180 * 86400);
      expect(home.pass!.credential.dpk, rig.keystore.publicKey);
    });

    test('a pass with plenty of time left makes no call to the server', () async {
      final rig = Rig();
      await onboard(rig);
      rig.advanceDays(30);
      rig.server.calls.clear();

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      expect(rig.server.calls, isEmpty);
    });

    test('if renewal cannot happen, the old pass keeps working', () async {
      final rig = Rig();
      await onboard(rig);
      final before = (await rig.passes.load())!.signedCredential;
      rig.advanceDays(170);
      rig.server.offline = true;

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      expect((await rig.passes.load())!.signedCredential, before);
    });

    test('a forgotten login does not stop the old pass either', () async {
      final rig = Rig();
      await onboard(rig);
      rig.advanceDays(170);
      rig.server.endAllSessions();

      expect((await rig.open()).stage, Stage.pass);
    });

    test('an expired pass is replaced automatically while the login and approval still stand', () async {
      final rig = Rig();
      await onboard(rig);
      rig.advanceDays(181);

      final home = await rig.open();
      expect(home.stage, Stage.pass);
      expect(home.pass!.credential.exp, greaterThan(rig.phoneNow));
    });

    test('an expired pass with no login says so on the sign-in page', () async {
      final rig = Rig();
      await onboard(rig);
      rig.advanceDays(181);
      await rig.sessions.clear();

      final home = await rig.open();
      expect(home.stage, Stage.signedOut);
      expect(home.problem, PassProblem.expired);
    });

    test('an expired pass and an ended login: sign in to renew, with a reason', () async {
      final rig = Rig();
      await onboard(rig);
      rig.advanceDays(181);
      rig.server.endAllSessions();

      final home = await rig.open();
      expect(home.stage, Stage.signedOut);
      expect(home.notice, contains('expired'));
    });
  });

  group('signing out', () {
    test('removes the login, the pass and the key, and the server forgets the login', () async {
      final rig = Rig();
      final home = await onboard(rig);
      await home.signOut();

      expect(home.stage, Stage.signedOut);
      expect(home.pass, isNull);
      expect(await rig.passes.load(), isNull);
      expect(await rig.sessions.load(), isNull);
      expect(rig.keystore.hasKey, isFalse);
      expect(rig.server.sessions, isEmpty);
    });

    test('works with no connection: the phone forgets regardless', () async {
      final rig = Rig();
      final home = await onboard(rig);
      rig.server.offline = true;
      await home.signOut();

      expect(await rig.passes.load(), isNull);
      expect(await rig.sessions.load(), isNull);
      expect(home.stage, Stage.signedOut);
    });

    test('another student can then use the same phone', () async {
      final rig = Rig();
      final home = await onboard(rig);
      await home.signOut();

      await home.requestCode('sravya@college.test');
      await home.verifyCode(home.devOtp!);
      expect(home.student?.name, 'Śrāvya Ñandini');
      expect(home.stage, Stage.details);
    });
  });

  group('signing up with a roll-number email', () {
    const mine = '25071a66j1@vnrvjiet.in';

    Future<(Rig, HomeController)> signedUp() async {
      final rig = Rig();
      rig.server.autoApprove = true;
      final home = await rig.open();
      await home.requestCode(mine);
      await home.verifyCode(home.devOtp!);
      return (rig, home);
    }

    test('a roll number the roster does not list can sign up, and is asked for its profile', () async {
      final (rig, home) = await signedUp();
      expect(home.stage, Stage.details);
      expect(home.student?.rollNumber, '25071A66J1');
      expect(home.profileComplete, isFalse);
      expect(rig.server.calls, contains('auth-verify-otp'));
    });

    test('name, branch and year are needed, and nothing is sent without them', () async {
      final (rig, home) = await signedUp();
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      expect(home.error, contains('name, branch and year'));
      await home.submitDetails(phone: '9876543210', photo: testPhoto(), name: 'Test Student', branch: '', year: 2);
      expect(home.error, contains('name, branch and year'));
      await home.submitDetails(phone: '9876543210', photo: testPhoto(), name: 'Test Student', branch: 'CSE-DS', year: 9);
      expect(home.error, contains('name, branch and year'));
      expect(rig.server.calls, isNot(contains('enrol')));
    });

    test('with the profile, the pass comes at once: no waiting for an admin', () async {
      final (rig, home) = await signedUp();
      await home.submitDetails(phone: '9876543210', photo: testPhoto(), name: '  Test   Student ', branch: 'cse-ds', year: 2);

      expect(home.stage, Stage.pass);
      expect(rig.server.lastProfile, {'name': 'Test Student', 'branch': 'cse-ds'.toUpperCase(), 'year': 2});
      final credential = home.pass!.credential;
      expect(credential.roll, '25071A66J1');
      expect(credential.name, 'Test Student');
      expect(credential.branch, 'CSE-DS');
      expect(credential.dpk, rig.keystore.publicKey);
    });

    test('a student the roster lists is not asked for a profile', () async {
      final rig = Rig();
      rig.server.autoApprove = true;
      final home = await rig.open();
      await home.requestCode('ravi.kumar@college.test');
      await home.verifyCode(home.devOtp!);
      expect(home.profileComplete, isTrue);
      await home.submitDetails(phone: '9876543210', photo: testPhoto());
      expect(home.stage, Stage.pass);
    });

    test('the app opened again before the profile was sent returns to the details page', () async {
      final (rig, _) = await signedUp();
      final again = await rig.open();
      expect(again.stage, Stage.details);
      expect(again.profileComplete, isFalse);
    });
  });

  group('the debug demo pass', () {
    test('is made without a server when the build allows it', () async {
      final rig = Rig(allowDemo: true);
      final home = await rig.open();
      await home.createDemoPass();
      expect(home.stage, Stage.pass);
      expect(home.pass!.credential.name, 'Demo Student');
      expect(rig.server.calls, isEmpty);
    });

    test('does nothing in a build that does not', () async {
      final rig = Rig(allowDemo: false);
      final home = await rig.open();
      await home.createDemoPass();
      expect(home.stage, Stage.signedOut);
      expect(await rig.passes.load(), isNull);
    });
  });
}
