import 'dart:async';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';

import 'keystore_signer.dart';
import 'pass_store.dart';

/// Seconds between signatures (spec section 10, `QR_REFRESH_S`). The scanner's `max_age_s` of 45 is
/// sized for this value; raise them together or not at all.
const int qrRefreshS = 30;

/// The spec asks the app to warn when the phone's clock is this far from the server's.
const int clockWarnS = 10;

int _systemNowS() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Why the pass cannot be shown. Each has its own words on screen and its own remedy.
enum PassProblem {
  /// Nothing stored: the student has not signed in on this phone.
  notActivated,

  /// Stored text is not a valid credential.
  corrupt,

  /// The Keystore has no key. The credential was issued to a key this phone no longer has.
  deviceKeyMissing,

  /// The Keystore has a key, but not the one named in the credential.
  deviceKeyChanged,
  expired,

  /// The Keystore did not answer.
  keystoreUnavailable,
}

class PassLoad {
  const PassLoad.ready(PassController this.controller) : problem = null;
  const PassLoad.problem(PassProblem this.problem) : controller = null;

  final PassController? controller;
  final PassProblem? problem;
}

/// Reads the stored credential and checks that this phone can use it, before any QR is drawn.
Future<PassLoad> openPass(PassStore store, KeystoreSigner signer, {int Function()? phoneNowS}) async {
  final now = phoneNowS ?? _systemNowS;
  final stored = await store.load();
  if (stored == null) return const PassLoad.problem(PassProblem.notActivated);

  final signed = parseSignedCredential(stored.signedCredential);
  if (signed == null) return const PassLoad.problem(PassProblem.corrupt);
  final Credential credential;
  try {
    credential = decodeCredential(signed.credentialBytes);
  } on FormatException {
    return const PassLoad.problem(PassProblem.corrupt);
  }

  final DeviceKey? key;
  try {
    key = await signer.existingKey();
  } catch (_) {
    return const PassLoad.problem(PassProblem.keystoreUnavailable);
  }
  if (key == null) return const PassLoad.problem(PassProblem.deviceKeyMissing);
  if (!listEquals(key.publicKey, credential.dpk)) return const PassLoad.problem(PassProblem.deviceKeyChanged);

  if (now() + stored.serverOffsetS >= credential.exp) return const PassLoad.problem(PassProblem.expired);

  return PassLoad.ready(PassController(
    signed: signed,
    credential: credential,
    signer: signer,
    serverOffsetS: stored.serverOffsetS,
    keySecurity: key.security,
    phoneNowS: now,
  ));
}

/// Why a pass that was showing stopped showing.
enum PassFault { expired, signingFailed }

/// Owns the live QR. One timer ticks every second: it redraws the countdown, and when the current QR
/// is [qrRefreshS] seconds old it asks the Keystore for a new signature. A timer that was starved while
/// the app was in the background therefore catches up on the first tick after resuming.
///
/// The QR is withdrawn, not left stale, whenever it cannot be renewed.
class PassController extends ChangeNotifier {
  PassController({
    required this.signed,
    required this.credential,
    required this.signer,
    this.serverOffsetS = 0,
    this.keySecurity = KeySecurity.unknown,
    this.refreshS = qrRefreshS,
    int Function()? phoneNowS,
  }) : _phoneNowS = phoneNowS ?? _systemNowS;

  final SignedCredential signed;
  final Credential credential;
  final DeviceSigner signer;
  final int serverOffsetS;
  final KeySecurity keySecurity;
  final int refreshS;
  final int Function() _phoneNowS;

  String? _qr;
  int? _signedAt;
  PassFault? _fault;
  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;

  /// The text to draw as a QR code, or null when there is none to show.
  String? get qr => _qr;
  PassFault? get fault => _fault;

  /// Unix seconds on the server's clock as best the phone knows it: the value the QR is stamped with.
  int get nowS => _phoneNowS() + serverOffsetS;

  /// Seconds until the QR is replaced, from [refreshS] down to 0.
  int get secondsLeft {
    final at = _signedAt;
    if (at == null) return refreshS;
    return (refreshS - (nowS - at)).clamp(0, refreshS);
  }

  bool get clockSuspect => serverOffsetS.abs() > clockWarnS;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
    tick();
  }

  /// Called every second and when the app returns to the foreground.
  void tick() {
    if (_disposed || _fault == PassFault.expired) return;
    if (nowS >= credential.exp) {
      // A QR signed a second ago would still be on screen, but every scanner now says EXPIRED.
      _qr = null;
      _signedAt = null;
      _fault = PassFault.expired;
      _timer?.cancel();
      _timer = null;
      notifyListeners();
      return;
    }
    final at = _signedAt;
    final due = at == null || nowS - at >= refreshS || nowS < at; // nowS < at: the clock moved back
    if (due) {
      unawaited(_refresh());
    } else {
      notifyListeners();
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      final ts = nowS;
      final text = await buildScanQr(signed, ts, signer);
      if (_fault == PassFault.expired) return; // expired while the Keystore was signing
      _qr = text;
      _signedAt = ts;
      _fault = null;
    } catch (_) {
      _qr = null;
      _signedAt = null;
      _fault = PassFault.signingFailed; // retried on the next tick
    } finally {
      _refreshing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
