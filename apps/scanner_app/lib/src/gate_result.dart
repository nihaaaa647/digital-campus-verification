import 'package:credential_core/credential_core.dart';

/// What the guard sees after a scan: green with the student, or red with a reason and a next step.
sealed class GateResult {
  const GateResult(this.atS);

  /// The scanner's corrected clock when the code was read, unix seconds.
  final int atS;
}

/// What a scan is for. The scanner starts in [verify]; the guard switches to [outPass] at the top of the screen
/// while students are going out, and back afterwards.
enum GateMode {
  /// Only checks the pass: green or red, nothing is saved, nothing is synced.
  verify,

  /// A valid pass is also recorded as an exit: saved on the phone, listed, and synced to the server.
  outPass,
}

class GateAccepted extends GateResult {
  const GateAccepted(super.atS, this.credential, {this.recorded = true});

  final Credential credential;

  /// Whether this scan was recorded as an exit (out pass mode) or only checked (verify mode).
  final bool recorded;
}

class GateRejected extends GateResult {
  const GateRejected(super.atS, this.failure);

  final ScanFailure failure;

  RedScreen get red => redScreenFor(failure);
}

/// The pass is valid but the exit could not be written to the scanner's log. It is shown in red because
/// it must not be waved through as recorded: the guard logs the student another way or scans again.
class GateNotSaved extends GateResult {
  const GateNotSaved(super.atS, this.credential);

  final Credential credential;

  RedScreen get red => const RedScreen(
        'Scan not saved',
        'The pass is valid, but this exit was not recorded. Scan again, or log the student manually. If it keeps happening, tell the admin.',
      );
}

/// The words on a red screen. docs/credential-spec.md section 9 fixes them.
class RedScreen {
  const RedScreen(this.title, this.nextStep);

  final String title;
  final String nextStep;
}

RedScreen redScreenFor(ScanFailure failure) => switch (failure) {
      ScanFailure.expired => const RedScreen(
          'Expired pass',
          'Ask the student to open the app online to refresh; otherwise send to the desk.',
        ),
      ScanFailure.revoked => const RedScreen('Revoked pass', 'Send to the desk.'),
      ScanFailure.badCollegeSig || ScanFailure.badDeviceSig || ScanFailure.malformed => const RedScreen(
          'Bad signature',
          'Ask the student to wait for the QR to refresh and scan again. If it repeats, log manually or send to the desk.',
        ),
      ScanFailure.unsupportedVersion => const RedScreen(
          'Pass needs an update',
          'Ask the student to update the app. Log manually meanwhile.',
        ),
      ScanFailure.unknownKeyVersion => const RedScreen(
          'Unknown ID',
          'The scanner has not synced a newer key. Sync on Wi-Fi and rescan. Log manually meanwhile.',
        ),
      ScanFailure.clockMismatch => const RedScreen(
          'Clock mismatch',
          "Ask the student to rescan once the QR refreshes. If it repeats, check the phone's automatic time and the scanner's last sync.",
        ),
    };

String passLabel(PassType? type) => switch (type) {
      PassType.student => 'Student',
      PassType.fresher => 'Fresher',
      PassType.visitor => 'Visitor',
      null => 'Pass',
    };
