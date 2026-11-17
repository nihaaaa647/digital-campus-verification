import 'package:flutter/material.dart';

/// "Śrāvya Ñandini" -> "ŚÑ", "Demo Student" -> "DS", "Madonna" -> "M". Takes whole letters, so a name with
/// combining marks or non-Latin script is not cut in half.
String initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final first = words.first.characters.first;
  final last = words.length > 1 ? words.last.characters.first : '';
  return '$first$last'.toUpperCase();
}

/// A circle with the person's initials. The colour is chosen from the name, so the same student always
/// gets the same colour and two students next to each other are easy to tell apart.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.name, this.size = 56, this.background, this.foreground});

  final String name;
  final double size;
  final Color? background;
  final Color? foreground;

  static const _palette = [
    Color(0xFF2346A0),
    Color(0xFF00796B),
    Color(0xFF8E24AA),
    Color(0xFFC2185B),
    Color(0xFFEF6C00),
    Color(0xFF455A64),
  ];

  static Color colorFor(String name) => _palette[name.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) % _palette.length];

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: background ?? colorFor(name)),
        child: Text(
          initialsOf(name),
          style: TextStyle(color: foreground ?? Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w700, letterSpacing: 0.5),
        ),
      ),
    );
  }
}

/// A small rounded label: a pass type, an expiry date, a mode.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.icon, this.background, this.foreground, this.compact = false});

  final String label;
  final IconData? icon;
  final Color? background;
  final Color? foreground;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ?? scheme.onSecondaryContainer;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: compact ? 5 : 8),
      decoration: BoxDecoration(color: background ?? scheme.secondaryContainer, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14 : 18, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontSize: compact ? 12 : 14, fontWeight: FontWeight.w700, letterSpacing: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app's mark: a rounded square in the brand colour with an icon.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.32),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [scheme.primary, Color.lerp(scheme.primary, Colors.black, 0.28)!]),
        ),
        child: Icon(icon, color: scheme.onPrimary, size: size * 0.56),
      ),
    );
  }
}

/// A dot that fades in and out. On a pass it shows the screen is live, which a screenshot is not.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 10});

  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      ),
    );
  }
}
