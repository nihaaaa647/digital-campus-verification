import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/src/id_card.dart';

// What a recogniser typically returns for a college ID card: header lines, then labelled fields, in reading order.
const _card = '''
VNR VIGNANA JYOTHI INSTITUTE OF ENGINEERING & TECHNOLOGY
Bachupally, Hyderabad
STUDENT IDENTITY CARD
Name : ANITA RAO
Roll No : 25071A66J1
Branch : CSE (DS)
B.Tech 2025-2029
Valid upto 2029
''';

final _oct2026 = DateTime(2026, 10, 28);

void main() {
  group('parseIdCard', () {
    test('reads the roll number, name, branch and year off a typical card', () {
      final card = parseIdCard(_card, now: _oct2026);
      expect(card.rollNumber, '25071A66J1');
      expect(card.name, 'Anita Rao');
      expect(card.branch, 'CSE-DS');
      expect(card.year, 2, reason: 'admitted in 2025, so in the second year in October 2026');
    });

    test('a name on the line after its label is found, and a header line is not taken for a name', () {
      final card = parseIdCard('VNR VIGNANA JYOTHI INSTITUTE\nSTUDENT NAME\nRAVI KUMAR K\nROLL NO\n25071A0003\nECE', now: _oct2026);
      expect(card.name, 'Ravi Kumar K');
      expect(card.rollNumber, '25071A0003');
      expect(card.branch, 'ECE');
    });

    test('with no label the first line that looks like a person is the name', () {
      final card = parseIdCard('VNR VIGNANA JYOTHI INSTITUTE OF ENGINEERING\nMEERA IYER\n25071A0004\nMECHANICAL ENGINEERING', now: _oct2026);
      expect(card.name, 'Meera Iyer');
      expect(card.branch, 'MECH');
    });

    test('misread letters in the digit part of the roll number are put right', () {
      expect(parseIdCard('Roll No: 2507IA66J1', now: _oct2026).rollNumber, '25071A66J1');
      expect(parseIdCard('Roll No: 2S07OA66J1', now: _oct2026).rollNumber, '25070A66J1');
    });

    test('lower case and a space inside the roll number are tolerated', () {
      expect(parseIdCard('roll no 25071a66j1', now: _oct2026).rollNumber, '25071A66J1');
      expect(parseIdCard('Roll No: 25071 A66J1', now: _oct2026).rollNumber, '25071A66J1');
    });

    test('branch codes: the specific one wins over the general one it contains', () {
      String? branch(String t) => parseIdCard(t, now: _oct2026).branch;
      expect(branch('CSE (AI & ML)'), 'CSE-AIML');
      expect(branch('Branch: CSE-AIML'), 'CSE-AIML');
      expect(branch('CSE (CS)'), 'CSE-CS');
      expect(branch('CSE (IoT)'), 'CSE-IOT');
      expect(branch('COMPUTER SCIENCE AND ENGINEERING'), 'CSE');
      expect(branch('AI&DS'), 'AI&DS');
      expect(branch('INFORMATION TECHNOLOGY'), 'IT');
      expect(branch('ELECTRICAL AND ELECTRONICS ENGINEERING'), 'EEE');
      expect(branch('CIVIL'), 'CIVIL');
    });

    test('an unknown branch printed after its label is kept, cut to 12 characters', () {
      expect(parseIdCard('Branch: BIOTECH', now: _oct2026).branch, 'BIOTECH');
      expect(parseIdCard('Branch: AEROSPACE ENGG', now: _oct2026).branch!.length, lessThanOrEqualTo(12));
    });

    test('year of study follows the admission year in the roll number, and a lateral entry is a year ahead', () {
      expect(parseIdCard('25071A66J1', now: DateTime(2026, 3, 1)).year, 1);
      expect(parseIdCard('25071A66J1', now: DateTime(2026, 10, 1)).year, 2);
      expect(parseIdCard('22071A66J1', now: DateTime(2026, 10, 1)).year, 5);
      expect(parseIdCard('26071D0001', now: DateTime(2026, 10, 1)).year, 2, reason: 'a D in the sixth place is a lateral entry');
      expect(parseIdCard('30071A0001', now: DateTime(2026, 10, 1)).year, 1, reason: 'never below the first year');
    });

    test('a card that could not be read gives nothing, not guesses', () {
      final card = parseIdCard('\n  \n', now: _oct2026);
      expect(card.rollNumber, isNull);
      expect(card.name, isNull);
      expect(card.branch, isNull);
      expect(card.year, isNull);
      expect(card.foundAnything, isFalse);
    });

    test('words from the card header, numbers and addresses are never taken for a name', () {
      final card = parseIdCard('VNR VIGNANA JYOTHI INSTITUTE\nBACHUPALLY HYDERABAD\nVALID UPTO 2029\nPHONE 040 2304 2758', now: _oct2026);
      expect(card.name, isNull);
    });

    test("the college's own name (Valluripally Nageswara Rao, the V N R) is never taken for the student's", () {
      // The header as a recogniser reads it, on one line or split, with the student's name unlabelled below it.
      const header = 'VALLURIPALLY NAGESWARA RAO\nVIGNANA JYOTHI INSTITUTE OF ENGINEERING & TECHNOLOGY\nAutonomous Institute, Affiliated to JNTUH\n';
      final card = parseIdCard('${header}ANITA RAO\n25071A66J1\nB.Tech CSE (DS)', now: _oct2026);
      expect(card.name, 'Anita Rao');
      expect(card.rollNumber, '25071A66J1');

      // No student name found at all is better than the college's name.
      expect(parseIdCard('${header}25071A66J1\nB.Tech CSE (DS)', now: _oct2026).name, isNull);
      expect(parseIdCard('Valluripally Nageswara Rao Vignana Jyothi Institute\n25071A66J1', now: _oct2026).name, isNull);
      expect(parseIdCard('V N R VIGNANA JYOTHI\nVALLURIPALLY NAGESWARA RAO', now: _oct2026).name, isNull);
    });

    test('a label like "Name of the Student" is understood, with the name on the same line or the next', () {
      expect(parseIdCard('VALLURIPALLY NAGESWARA RAO\nName of the Student : RAVI KUMAR\n25071A0003', now: _oct2026).name, 'Ravi Kumar');
      expect(parseIdCard('VALLURIPALLY NAGESWARA RAO\nNAME OF THE STUDENT\nMEERA IYER\n25071A0004', now: _oct2026).name, 'Meera Iyer');
      expect(parseIdCard("VNR\nSTUDENT'S NAME: SRAVYA NANDINI", now: _oct2026).name, 'Sravya Nandini');
    });

    test('names with initials and hyphens keep them', () {
      expect(parseIdCard('Name: SRI LAKSHMI K.V.\n25071A0001', now: _oct2026).name, 'Sri Lakshmi K.V.');
    });
  });

  test('yearOfStudy never leaves 1 to 6', () {
    expect(yearOfStudy(2010, DateTime(2026, 10, 1)), 6);
    expect(yearOfStudy(2030, DateTime(2026, 10, 1)), 1);
  });
}
