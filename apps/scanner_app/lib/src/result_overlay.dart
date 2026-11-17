import 'package:campus_ui/campus_ui.dart';
import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';

import 'gate_result.dart';

const Color _ink = Color(0xFF111827);
const Color _muted = Color(0xFF5B6475);

/// The full-screen answer: green with the student, or red with the reason. White card on a solid colour,
/// so the verdict reads from across a gate and the details read up close. Tap anywhere to scan the next
/// pass; the bar at the bottom shows how long until it goes back by itself.
class ResultOverlay extends StatelessWidget {
  const ResultOverlay(
      {super.key,
      required this.result,
      required this.hold,
      required this.onTap});

  final GateResult result;

  /// How long the screen stays before returning to scanning, for the progress bar.
  final Duration hold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.campus;
    final (base, icon, heading) = switch (result) {
      GateAccepted() => (colors.success, Icons.check_rounded, 'VALID PASS'),
      GateRejected() => (colors.danger, Icons.close_rounded, 'NOT VALID'),
      GateNotSaved() => (
          colors.danger,
          Icons.priority_high_rounded,
          'NOT SAVED'
        ),
    };

    return LayoutBuilder(builder: (context, box) {
      // Short screens (and large system text) get a tighter layout so the whole reason fits without scrolling.
      final compact = box.maxHeight < 700;
      final card = switch (result) {
        GateAccepted(:final credential, :final atS, :final recorded) => _StudentCard(
            credential: credential,
            compact: compact,
            footer: _SavedLine(atS: atS, color: colors.success, recorded: recorded)),
        GateRejected(:final red) =>
          _ReasonCard(red: red, color: colors.danger, compact: compact),
        GateNotSaved(:final credential, :final red) => _StudentCard(
            credential: credential,
            compact: compact,
            footer:
                _ReasonText(red: red, color: colors.danger, compact: compact)),
      };
      return Semantics(
        liveRegion: true,
        container: true,
        label: heading,
        child: Material(
          color: base,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [base, Color.lerp(base, Colors.black, 0.3)!]),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    // Centred when it fits, scrollable when large system text makes it taller than the screen.
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _Badge(
                                  icon: icon,
                                  color: base,
                                  size: compact ? 84 : 116),
                              SizedBox(height: compact ? 10 : 18),
                              Text(
                                heading,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: compact ? 17 : 20,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 4),
                              ),
                              if (result case GateAccepted(:final recorded)) ...[
                                SizedBox(height: compact ? 8 : 12),
                                _ModeChip(recorded: recorded),
                              ],
                              SizedBox(height: compact ? 14 : 22),
                              card,
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 20),
                      child: Column(
                        children: [
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 1, end: 0),
                            duration: hold,
                            builder: (context, value, _) => ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: value,
                                minHeight: 5,
                                backgroundColor: Colors.white24,
                                valueColor:
                                    const AlwaysStoppedAnimation(Colors.white),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Tap to scan the next pass',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color, required this.size});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.55, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10))
          ],
        ),
        child: Icon(icon, size: size * 0.65, color: color),
      ),
    );
  }
}

BoxDecoration _cardDecoration() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(CampusTheme.radiusCard),
      boxShadow: [
        BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 30,
            offset: const Offset(0, 12))
      ],
    );

/// Who the pass belongs to, with [footer] under it (a confirmation, or what went wrong).
class _StudentCard extends StatelessWidget {
  const _StudentCard(
      {required this.credential, required this.footer, required this.compact});

  final Credential credential;
  final Widget footer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(name: credential.name, size: compact ? 48 : 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      credential.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _ink,
                          fontSize: compact ? 20 : 24,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      credential.roll,
                      style: const TextStyle(
                          color: _muted,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 12 : 18),
              child: const Divider(height: 1, color: Color(0xFFE3E7EF))),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  flex: 5,
                  child: _Fact(label: 'BRANCH', value: credential.branch)),
              Expanded(
                  flex: 2,
                  child: _Fact(label: 'YEAR', value: '${credential.year}')),
              Expanded(
                  flex: 3,
                  child: _Fact(
                      label: 'PASS', value: passLabel(credential.passType))),
            ],
          ),
          SizedBox(height: compact ? 12 : 18),
          footer,
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: _muted,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2)),
        const SizedBox(height: 3),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: _ink, fontSize: 19, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

/// Says which mode produced this green screen, so a guard never mistakes a check for a recorded exit.
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.recorded});

  final bool recorded;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(999)),
      child: Text(
        recorded ? 'OUT PASS RECORDED' : 'VERIFY ONLY · NOT RECORDED',
        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.2),
      ),
    );
  }
}

class _SavedLine extends StatelessWidget {
  const _SavedLine({required this.atS, required this.color, this.recorded = true});

  final int atS;
  final Color color;

  /// Out pass mode saves the exit; verify mode only checked the pass.
  final bool recorded;

  @override
  Widget build(BuildContext context) {
    final t = DateTime.fromMillisecondsSinceEpoch(atS * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return Row(
      children: [
        Icon(Icons.check_circle_rounded, color: color, size: 20),
        const SizedBox(width: 8),
        Text('${recorded ? 'Saved' : 'Checked'} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}${recorded ? '' : ' · not recorded'}',
            style: TextStyle(
                color: color, fontSize: 15, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _ReasonText extends StatelessWidget {
  const _ReasonText(
      {required this.red, required this.color, required this.compact});

  final RedScreen red;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(red.title,
            style: TextStyle(
                color: color,
                fontSize: compact ? 19 : 22,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(red.nextStep,
            style: TextStyle(
                color: _ink, fontSize: compact ? 16 : 18, height: 1.35)),
      ],
    );
  }
}

/// Why a pass was refused, and what the guard does about it.
class _ReasonCard extends StatelessWidget {
  const _ReasonCard(
      {required this.red, required this.color, required this.compact});

  final RedScreen red;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 18 : 24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(red.title,
              style: TextStyle(
                  color: color,
                  fontSize: compact ? 23 : 28,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.3)),
          Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 10 : 16),
              child: const Divider(height: 1, color: Color(0xFFE3E7EF))),
          const Text('WHAT TO DO',
              style: TextStyle(
                  color: _muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Text(red.nextStep,
              style: TextStyle(
                  color: _ink, fontSize: compact ? 17 : 20, height: 1.35)),
        ],
      ),
    );
  }
}
