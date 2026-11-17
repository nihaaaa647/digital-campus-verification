import 'package:flutter/material.dart';

/// Colours that carry meaning in both apps, whatever the theme: a pass that is valid, one that is not,
/// and a warning. Every pair keeps white-on-colour text above 4.5:1 so it reads in sunlight.
@immutable
class CampusColors extends ThemeExtension<CampusColors> {
  const CampusColors({
    required this.success,
    required this.onSuccess,
    required this.danger,
    required this.onDanger,
    required this.warning,
    required this.onWarning,
    required this.live,
  });

  final Color success;
  final Color onSuccess;
  final Color danger;
  final Color onDanger;
  final Color warning;
  final Color onWarning;

  /// The pulsing dot that shows a pass is a live screen and not a screenshot.
  final Color live;

  static const CampusColors light = CampusColors(
    success: Color(0xFF137333),
    onSuccess: Colors.white,
    danger: Color(0xFFB3261E),
    onDanger: Colors.white,
    warning: Color(0xFFFFC107),
    onWarning: Color(0xFF1F1A00),
    live: Color(0xFF1E9E4A),
  );

  static const CampusColors dark = CampusColors(
    success: Color(0xFF137333),
    onSuccess: Colors.white,
    danger: Color(0xFFB3261E),
    onDanger: Colors.white,
    warning: Color(0xFFFFC107),
    onWarning: Color(0xFF1F1A00),
    live: Color(0xFF4ADE80),
  );

  @override
  CampusColors copyWith({Color? success, Color? onSuccess, Color? danger, Color? onDanger, Color? warning, Color? onWarning, Color? live}) {
    return CampusColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      live: live ?? this.live,
    );
  }

  @override
  CampusColors lerp(CampusColors? other, double t) {
    if (other == null) return this;
    return CampusColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      live: Color.lerp(live, other.live, t)!,
    );
  }
}

extension CampusColorsOf on BuildContext {
  CampusColors get campus => Theme.of(this).extension<CampusColors>() ?? CampusColors.light;
}
