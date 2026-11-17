import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'photo_source.dart';

/// What could be read off a college ID card. Any field may be missing: the student checks and corrects them.
class CardDetails {
  const CardDetails({this.rollNumber, this.name, this.branch, this.year, this.text = ''});

  /// Upper case, e.g. `25071A66J1`.
  final String? rollNumber;

  /// In capitals and lower case, e.g. `Anita Rao`.
  final String? name;

  /// A short code of at most 12 characters, e.g. `CSE-DS`.
  final String? branch;

  /// Year of study (1 to 6), worked out from the roll number's admission year.
  final int? year;

  /// Everything the recogniser read, for the debug log.
  final String text;

  bool get foundAnything => rollNumber != null || name != null || branch != null;
}

/// Words that appear on a card but are not a student's name. A line containing any of them is never a name. The
/// college's own name is the trap: "Valluripally Nageswara Rao" is the V N R of the header, and reads like a person.
const _notNames = <String>[
  'VNR', 'VIGNANA', 'JYOTHI', 'INSTITUTE', 'ENGINEERING', 'TECHNOLOGY', 'COLLEGE', 'UNIVERSITY', 'AUTONOMOUS', 'STUDENT',
  'IDENTITY', 'CARD', 'ROLL', 'BRANCH', 'DEPARTMENT', 'VALID', 'B.TECH', 'BTECH', 'COURSE', 'PROGRAMME', 'ADDRESS', 'PRINCIPAL',
  'SIGNATURE', 'PHONE', 'MOBILE', 'BLOOD', 'GROUP', 'HYDERABAD', 'TELANGANA', 'BACHUPALLY', 'NIZAMPET', 'YEAR', 'BATCH', 'EMAIL', 'ID',
  'VALLURIPALLY', 'VALLURUPALLY', 'VALLURIPALLI', 'NAGESWARA', 'NAGESWAR', 'NAGESHWARA', 'ACCREDITED', 'AFFILIATED', 'JNTUH', 'NAAC', 'NBA',
  'ESTD', 'WEBSITE', 'WWW', 'SCHOOL', 'TECHNOLOGICAL', 'SCIENCES', 'ACADEMY', 'FOUNDATION', 'SOCIETY', 'TRUST', 'REGISTRAR', 'ISSUED',
];

/// Pieces of the college's name that may be split across words or misread, so they are matched inside a line.
const _collegeFragments = <String>['VALLUR', 'NAGESWAR', 'NAGESHWAR', 'VIGNANA', 'JYOTHI', 'INSTITUTE'];

/// Branch codes in the order they are tried: the specific ones before the general ones they contain.
final _branches = <(RegExp, String)>[
  (RegExp(r'CSE\s*[\(\-\s]*\s*(AI\s*&?\s*ML|AIML)'), 'CSE-AIML'),
  (RegExp(r'CSE\s*[\(\-\s]*\s*(DS|DATA\s*SCIENCE)\b'), 'CSE-DS'),
  (RegExp(r'CSE\s*[\(\-\s]*\s*(CS|CYBER)'), 'CSE-CS'),
  (RegExp(r'CSE\s*[\(\-\s]*\s*IOT'), 'CSE-IOT'),
  (RegExp(r'AI\s*&\s*DS|\bAIDS\b'), 'AI&DS'),
  (RegExp(r'\bCSBS\b'), 'CSBS'),
  (RegExp(r'\bCSE\b|COMPUTER\s+SCIENCE'), 'CSE'),
  (RegExp(r'\bECE\b|ELECTRONICS\s*(AND|&)\s*COMM'), 'ECE'),
  (RegExp(r'\bEEE\b|ELECTRICAL\s*(AND|&)\s*ELECTRONICS'), 'EEE'),
  (RegExp(r'\bEIE\b'), 'EIE'),
  (RegExp(r'\bIT\b|INFORMATION\s+TECHNOLOGY'), 'IT'),
  (RegExp(r'\bMECH\b|MECHANICAL'), 'MECH'),
  (RegExp(r'\bCIVIL\b'), 'CIVIL'),
];

/// Year of study for a student admitted in [admissionYear], on [now]. The academic year starts in June.
int yearOfStudy(int admissionYear, DateTime now, {bool lateralEntry = false}) {
  final year = now.year - admissionYear + (now.month >= 6 ? 1 : 0) + (lateralEntry ? 1 : 0);
  return year.clamp(1, 6);
}

String _titleCase(String s) => s
    .toLowerCase()
    .split(' ')
    .where((w) => w.isNotEmpty)
    .map((w) => RegExp(r'^([a-z]\.)+$').hasMatch(w) ? w.toUpperCase() : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

/// Reads the roll number, name, branch and year from the text a recogniser found on a college ID card
/// (roll numbers look like `25071A66J1`). Everything is a best guess for the student to confirm.
CardDetails parseIdCard(String raw, {DateTime? now}) {
  final text = raw.toUpperCase();
  final lines = text.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  // Roll number. The first five characters are digits, so a misread O, I or S there is put right.
  String? roll;
  final rollMatch = RegExp(r'(?<![0-9A-Z])([0-9OIS]{5})([A-Z])([0-9A-Z]{4})(?![0-9A-Z])').firstMatch(text.replaceAll(RegExp(r'(?<=\d)[ \-](?=[0-9A-Z]{5}\b)'), ''));
  if (rollMatch != null) {
    final digits = rollMatch.group(1)!.replaceAll('O', '0').replaceAll('I', '1').replaceAll('S', '5');
    roll = '$digits${rollMatch.group(2)}${rollMatch.group(3)}';
  }

  // Name: after a "NAME" label if there is one, else the first line that looks like a person's name.
  String? name;
  // The college's header sits at the top; a student's name is never above its last line.
  var headerEnd = -1;
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'INSTITUTE|JYOTHI|VIGNANA').hasMatch(lines[i]) && i < 5) headerEnd = i;
  }
  final candidates = [for (var i = headerEnd + 1; i < lines.length; i++) lines[i]];
  for (var i = 0; i < lines.length && name == null; i++) {
    final m = RegExp(r'^(?:STUDENT(?:\S?S)?\s*NAME|NAME(?:\s+OF\s+(?:THE\s+)?STUDENT)?|NAME)\s*[:\-.]*\s*(.*)$').firstMatch(lines[i]);
    if (m == null) continue;
    final same = m.group(1)!.trim();
    final candidate = same.isNotEmpty ? same : (i + 1 < lines.length ? lines[i + 1] : '');
    if (_looksLikeName(candidate, allowSingleWord: true)) name = candidate;
  }
  name ??= candidates.where((l) => _looksLikeName(l)).cast<String?>().firstWhere((_) => true, orElse: () => null);
  if (name != null) name = _titleCase(name.replaceAll(RegExp(r'^[^A-Z]+|[^A-Z.]+$'), ''));

  // Branch.
  String? branch;
  for (final (pattern, code) in _branches) {
    if (pattern.hasMatch(text)) {
      branch = code;
      break;
    }
  }
  if (branch == null) {
    final m = RegExp(r'BRANCH\s*[:\-]*\s*([A-Z0-9&() \-]{2,16})').firstMatch(text);
    final labelled = m?.group(1)?.replaceAll(RegExp(r'[() ]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (labelled != null && labelled.isNotEmpty) branch = labelled.length > 12 ? labelled.substring(0, 12) : labelled;
  }

  int? year;
  if (roll != null) {
    year = yearOfStudy(2000 + int.parse(roll.substring(0, 2)), now ?? DateTime.now(), lateralEntry: roll[5] == 'D');
  }
  return CardDetails(rollNumber: roll, name: name, branch: branch, year: year, text: raw);
}

bool _looksLikeName(String line, {bool allowSingleWord = false}) {
  final words = line.trim().split(RegExp(r'\s+'));
  if (words.length > 5 || (!allowSingleWord && words.length < 2)) return false;
  if (!RegExp(r'^[A-Z][A-Z .\-]{2,40}$').hasMatch(line.trim())) return false;
  for (final w in words) {
    if (_notNames.contains(w.replaceAll(RegExp(r'[^A-Z.]'), ''))) return false;
  }
  final squashed = line.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  if (_collegeFragments.any(squashed.contains)) return false;
  return !RegExp(r'\d').hasMatch(line);
}

/// Reads a college ID card: takes (or picks) a photo of it and recognises the text on the phone, with no
/// network. The photo of the card is deleted straight after; it never leaves the phone.
abstract interface class CardReader {
  /// The details on the card, or null if the student backed out.
  Future<CardDetails?> read(PhotoOrigin origin);
}

class DeviceCardReader implements CardReader {
  DeviceCardReader({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<CardDetails?> read(PhotoOrigin origin) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: origin == PhotoOrigin.camera ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 90,
      );
    } on Exception catch (e) {
      throw PhotoException(e.toString());
    }
    if (file == null) return null;
    final recogniser = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recogniser.processImage(InputImage.fromFilePath(file.path));
      return parseIdCard(result.text);
    } on Exception catch (e) {
      throw PhotoException('could not read the card: $e');
    } finally {
      await recogniser.close();
      try {
        await File(file.path).delete();
      } on Exception {
        // A leftover cache file is cleared by Android with the rest of the cache.
      }
    }
  }
}
