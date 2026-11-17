import 'package:flutter/material.dart';

import 'campus_colors.dart';

/// The look of both apps: one brand blue, calm tinted backgrounds, generous radii, and type with a clear
/// order (a bold name, a medium line under it, small labels).
abstract final class CampusTheme {
  static const Color brand = Color(0xFF2346A0);

  /// Radii used across the apps, so cards and sheets feel related.
  static const double radiusCard = 28;
  static const double radiusInner = 18;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final scheme = ColorScheme.fromSeed(seedColor: brand, brightness: brightness);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
    final text = base.textTheme;

    return base.copyWith(
      scaffoldBackgroundColor: isLight ? const Color(0xFFF2F5FB) : const Color(0xFF0D1220),
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3, height: 1.15),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.2),
        labelSmall: text.labelSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.8),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), shape: const StadiumBorder()),
      ),
      extensions: [isLight ? CampusColors.light : CampusColors.dark],
    );
  }
}
