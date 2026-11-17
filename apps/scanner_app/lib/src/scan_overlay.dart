import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What sits over the camera while the scanner waits: the picture dimmed everywhere except a clear
/// window with corner brackets, a slow line sweeping through it, and a one-line instruction.
///
/// The camera reads the whole frame, so a code does not have to be inside the window; the window only
/// shows the guard and the student where to hold it.
class ScanOverlay extends StatefulWidget {
  const ScanOverlay({super.key, this.hint = "Point at the student's QR code"});

  /// The line under the framing window.
  final String hint;

  @override
  State<ScanOverlay> createState() => _ScanOverlayState();
}

class _ScanOverlayState extends State<ScanOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat(reverse: true);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final side = math.min(box.maxWidth * 0.74, 320.0);
        final window = Rect.fromCenter(center: Offset(box.maxWidth / 2, box.maxHeight * 0.40), width: side, height: side);
        return Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _WindowPainter(window))),
            Positioned.fromRect(
              rect: window.deflate(16),
              child: AnimatedBuilder(
                animation: _sweep,
                builder: (context, _) => Align(
                  alignment: Alignment(0, -1 + 2 * Curves.easeInOut.transform(_sweep.value)),
                  child: const _SweepLine(),
                ),
              ),
            ),
            Positioned(left: 24, right: 24, top: window.bottom + 28, child: Center(child: _Hint(widget.hint))),
          ],
        );
      },
    );
  }
}

class _SweepLine extends StatelessWidget {
  const _SweepLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 3,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white, Colors.white.withValues(alpha: 0)]),
        boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.5), blurRadius: 12, spreadRadius: 1)],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowPainter extends CustomPainter {
  _WindowPainter(this.window);

  final Rect window;

  static const double _radius = 30;
  static const double _arm = 46;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(window, const Radius.circular(_radius)));
    canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: 0.58));

    final bracket = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    // One bracket per corner: a straight arm, the rounded corner, a straight arm. (sx, sy) point inward.
    void corner(double x, double y, double sx, double sy) {
      final path = Path()
        ..moveTo(x, y + sy * _arm)
        ..lineTo(x, y + sy * _radius)
        ..arcToPoint(Offset(x + sx * _radius, y), radius: const Radius.circular(_radius), clockwise: sx * sy > 0)
        ..lineTo(x + sx * _arm, y);
      canvas.drawPath(path, bracket);
    }

    corner(window.left, window.top, 1, 1);
    corner(window.right, window.top, -1, 1);
    corner(window.left, window.bottom, 1, -1);
    corner(window.right, window.bottom, -1, -1);
  }

  @override
  bool shouldRepaint(_WindowPainter old) => old.window != window;
}
