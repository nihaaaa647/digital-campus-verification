import 'dart:async';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';

import 'gate_result.dart';
import 'scan_log.dart';

int _systemNowS() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Where and by whom scans are made, stamped on every log row. Activation and guard login will supply
/// real values; until they exist the scanner uses [devGateContext].
class GateContext {
  const GateContext({required this.gate, required this.guardId});

  final String gate;
  final String guardId;
}

const GateContext devGateContext = GateContext(gate: 'Main', guardId: 'G-DEV');

/// Turns camera detections into results for the guard: verifies each new code, saves the exit when the guard is
/// in [GateMode.outPass], holds the result on screen, and ignores a code that is still in front of the camera.
///
/// In [GateMode.verify] (the default) a valid pass is only checked: it is not written to the log, not counted, and
/// not synced. Recording an exit is something the guard asks for by switching to out pass mode.
///
/// In out pass mode a pass is shown green only after its row is committed to the [log] (PRD G7). If the row cannot be
/// written, the guard sees a red "not saved" screen instead: a green screen for an unrecorded exit
/// would be worse than a delay.
///
/// One result is on screen at a time and detections are ignored while it is, and while a row is being
/// written. Green holds for [acceptedHold], red for [rejectedHold] so the guard can read the next
/// step; a tap ends either.
class GateController extends ChangeNotifier {
  GateController({
    required this.keys,
    required this.log,
    this.context = devGateContext,
    this.savedCount = 0,
    GateMode mode = GateMode.verify,
    this.revoked = const [],
    this.serverOffsetS = 0,
    this.onSaved,
    int Function()? phoneNowS,
    String Function()? newId,
    this.acceptedHold = const Duration(seconds: 3),
    this.rejectedHold = const Duration(seconds: 6),
  })  : _mode = mode,
        _phoneNowS = phoneNowS ?? _systemNowS,
        _newId = newId ?? newScanId;

  /// The same student is not accepted twice inside this many seconds (PRD G6).
  static const int sameStudentDebounceS = 5;

  /// College public keys by key version.
  final Map<int, Uint8List> keys;

  /// Where accepted scans are written before they are shown.
  final ScanLog log;
  final GateContext context;

  /// Entries from a revocation list that already passed `verifyRevocationList`.
  final Iterable<RevocationEntry> revoked;

  /// Server time minus this phone's time, recorded at the last sync (PRD G14). Changes after each sync.
  int serverOffsetS;

  /// Called after each exit is safely in the log, so the sync can start soon.
  final VoidCallback? onSaved;
  final Duration acceptedHold;
  final Duration rejectedHold;
  final int Function() _phoneNowS;
  final String Function() _newId;

  /// Rows waiting in the log for the server to confirm, kept up to date as scans are saved.
  int savedCount;

  GateMode _mode;
  GateResult? _current;
  Timer? _timer;
  bool _saving = false;
  bool _disposed = false;
  final Map<int, int> _acceptedAt = {}; // sid -> when it was last accepted
  final Map<String, int> _ignoreUntil = {}; // code text -> until when to ignore it

  int get nowS => _phoneNowS() + serverOffsetS;

  /// The result being shown, or null while the scanner is waiting for a code.
  GateResult? get current => _current;

  /// Verify (check only) or out pass (check and record).
  GateMode get mode => _mode;

  /// Switches what scans are for. Anything on screen is dismissed and the "already seen" memory is cleared, so a
  /// pass that was only verified can be recorded straight away by scanning it again in out pass mode.
  void setMode(GateMode mode) {
    if (_disposed || mode == _mode) return;
    _mode = mode;
    _ignoreUntil.clear();
    _acceptedAt.clear();
    _timer?.cancel();
    _timer = null;
    _current = null;
    notifyListeners();
  }

  /// The sync changed what is waiting in the log (rows were confirmed and deleted).
  void setSavedCount(int count) {
    if (_disposed || count == savedCount) return;
    savedCount = count;
    notifyListeners();
  }

  /// A sync measured a new server-time offset.
  void setServerOffset(int offsetS) {
    if (_disposed) return;
    serverOffsetS = offsetS;
  }

  /// How long [result] stays on screen before the scanner goes back to waiting.
  Duration holdFor(GateResult result) => result is GateAccepted ? acceptedHold : rejectedHold;

  /// Called for every QR the camera reads, many times a second while one is in view.
  void onCode(String text) {
    if (_disposed || _current != null || _saving) return;
    final now = nowS;
    _ignoreUntil.removeWhere((_, until) => until <= now);
    _acceptedAt.removeWhere((_, at) => now - at >= sameStudentDebounceS);
    if (_ignoreUntil.containsKey(text)) return;

    final outcome = verifyScan(text, now: now, keys: keys, revoked: revoked);
    if (kDebugMode) _debugLog(outcome, text);
    switch (outcome) {
      case ScanAccepted(:final credential) when _mode == GateMode.verify:
        // Checking only: shown, never written. The same code is not shown again for a few seconds, so one pass in
        // front of the camera does not flash green on every frame.
        _ignoreUntil[text] = now + sameStudentDebounceS;
        _show(GateAccepted(now, credential, recorded: false), acceptedHold);
      case ScanAccepted(:final credential):
        // The very same code stays a duplicate for as long as it could still pass the time window;
        // a refreshed code from the same student is a duplicate for the debounce period.
        final repeat = _acceptedAt.containsKey(credential.sid);
        _ignoreUntil[text] = now + (repeat ? sameStudentDebounceS : defaultMaxAgeS + defaultMaxFutureS);
        if (repeat) return;
        _acceptedAt[credential.sid] = now;
        unawaited(_saveThenShow(credential, now, text));
      case ScanRejected(:final failure):
        _ignoreUntil[text] = now + sameStudentDebounceS;
        _show(GateRejected(now, failure), rejectedHold);
    }
  }

  Future<void> _saveThenShow(Credential credential, int now, String text) async {
    _saving = true;
    var saved = false;
    try {
      await log.append(ScanRecord(
        scanId: _newId(),
        scannedAt: now,
        studentId: credential.sid,
        rollNumber: credential.roll,
        gate: context.gate,
        guardId: context.guardId,
        name: credential.name,
        branch: credential.branch,
        year: credential.year,
      ));
      saved = true;
    } catch (error) {
      if (kDebugMode) debugPrint('gate: could not save scan: $error');
    } finally {
      _saving = false;
    }
    if (_disposed) return;
    if (saved) {
      savedCount++;
      _show(GateAccepted(now, credential), acceptedHold);
      onSaved?.call();
    } else {
      // Nothing was recorded, so this exit must be tried again: forget it was accepted.
      _acceptedAt.remove(credential.sid);
      _ignoreUntil[text] = now + sameStudentDebounceS;
      _show(GateNotSaved(now, credential), rejectedHold);
    }
  }

  /// Debug builds only: what the camera read and what verification made of it, for `adb logcat`.
  /// Shows the length and first characters of the code, never the whole code.
  void _debugLog(ScanOutcome outcome, String text) {
    final head = text.length <= 12 ? text : text.substring(0, 12);
    final verdict = switch (outcome) {
      ScanAccepted(:final credential) => 'ACCEPTED sid=${credential.sid}',
      ScanRejected(:final failure) => 'REJECTED ${failure.code}',
    };
    debugPrint('gate: $verdict, ${text.length} chars, starts "$head", clock $nowS');
  }

  void _show(GateResult result, Duration hold) {
    _timer?.cancel();
    _current = result;
    _timer = Timer(hold, dismiss);
    notifyListeners();
  }

  /// Back to scanning. Safe to call when nothing is showing.
  void dismiss() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
