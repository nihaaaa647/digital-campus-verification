import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('initialsOf', () {
    test('first letter of the first and last word, upper case', () {
      expect(initialsOf('Demo Student'), 'DS');
      expect(initialsOf('  anita   kumari  rao '), 'AR');
    });

    test('one word gives one letter, nothing gives a placeholder', () {
      expect(initialsOf('Madonna'), 'M');
      expect(initialsOf('   '), '?');
      expect(initialsOf(''), '?');
    });

    test('keeps accented and non-Latin letters whole', () {
      expect(initialsOf('Śrāvya Ñandini'), 'ŚÑ');
      expect(initialsOf('अनीता शर्मा'), 'अश');
      expect(initialsOf('émile zola'), 'ÉZ'); // e + combining acute stays together
    });
  });

  test('the same name always gets the same avatar colour', () {
    expect(InitialsAvatar.colorFor('Demo Student'), InitialsAvatar.colorFor('Demo Student'));
  });

  group('themes', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      test('$brightness builds and carries the meaning colours', () {
        final theme = brightness == Brightness.light ? CampusTheme.light() : CampusTheme.dark();
        expect(theme.useMaterial3, isTrue);
        expect(theme.brightness, brightness);
        expect(theme.extension<CampusColors>(), isNotNull);
      });
    }

    test('white text on the success and danger colours is readable (at least 4.5:1)', () {
      double luminance(Color c) => c.computeLuminance();
      double ratio(Color a, Color b) {
        final l1 = luminance(a), l2 = luminance(b);
        return (l1 > l2 ? l1 + 0.05 : l2 + 0.05) / (l1 > l2 ? l2 + 0.05 : l1 + 0.05);
      }

      for (final c in [CampusColors.light, CampusColors.dark]) {
        expect(ratio(c.success, c.onSuccess), greaterThanOrEqualTo(4.5));
        expect(ratio(c.danger, c.onDanger), greaterThanOrEqualTo(4.5));
        expect(ratio(c.warning, c.onWarning), greaterThanOrEqualTo(4.5));
      }
    });
  });
}
