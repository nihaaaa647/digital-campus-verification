import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_view.dart';
import 'gate_controller.dart';
import 'gate_result.dart';
import 'result_overlay.dart';
import 'scan_overlay.dart';
import 'sync_service.dart';

/// The guard's screen: the camera with a framing window, a bar of status at each edge, and a full-screen
/// green or red result over it. The screen owns [controller] and disposes it.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.controller, this.cameraBuilder = defaultCameraBuilder, this.devKeys = false, this.sync, this.onActivate, this.onOpenRegister});

  final GateController controller;

  /// Where the saved scans go; null hides the sync status (tests, and builds with no sync).
  final SyncService? sync;

  /// Opens the activation screen. The sync pill offers it when the scanner is not activated, or when the
  /// server no longer accepts its token.
  final VoidCallback? onActivate;

  /// Opens the out pass register (everyone let through, with a CSV export). Null hides the button.
  final VoidCallback? onOpenRegister;
  final CameraBuilder cameraBuilder;

  /// Shows a banner saying the scanner trusts the public test keys.
  final bool devKeys;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  GateResult? _lastFeltResult;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_feedback);
  }

  /// A buzz for every new result: one firm pulse for green, two for red, so a guard looking at the
  /// student and not the screen still knows.
  void _feedback() {
    final result = widget.controller.current;
    if (result == null || identical(result, _lastFeltResult)) return;
    _lastFeltResult = result;
    switch (result) {
      case GateAccepted():
        HapticFeedback.mediumImpact();
      case GateRejected() || GateNotSaved():
        HapticFeedback.heavyImpact();
        Future<void>.delayed(const Duration(milliseconds: 180), HapticFeedback.heavyImpact);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_feedback);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.black),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            widget.cameraBuilder(context, widget.controller.onCode),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => IgnorePointer(
                child: ScanOverlay(hint: widget.controller.mode == GateMode.outPass ? 'Out pass mode · each scan is recorded' : "Point at the student's QR code"),
              ),
            ),
            _TopBar(controller: widget.controller, devKeys: widget.devKeys),
            Align(
              alignment: Alignment.bottomCenter,
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) => _BottomPanel(count: widget.controller.savedCount, sync: widget.sync, onActivate: widget.onActivate, onOpenList: widget.onOpenRegister),
              ),
            ),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final result = widget.controller.current;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 140),
                  child: result == null
                      ? const SizedBox.shrink(key: ValueKey('none'))
                      : ResultOverlay(
                          key: ValueKey(result),
                          result: result,
                          hold: widget.controller.holdFor(result),
                          onTap: widget.controller.dismiss,
                        ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.devKeys});

  final GateController controller;
  final bool devKeys;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0.72), Colors.black.withValues(alpha: 0)]),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const BrandMark(icon: Icons.qr_code_scanner_rounded, size: 40),
                    const SizedBox(width: 12),
                    // Shrinks to fit instead of wrapping when the switch beside it leaves little room.
                    const Expanded(
                      flex: 2,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text('Campus Gate', maxLines: 1, style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 5,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: ListenableBuilder(
                          listenable: controller,
                          builder: (context, _) => _ModeSwitch(mode: controller.mode, onChanged: controller.setMode),
                        ),
                      ),
                    ),
                  ],
                ),
                if (devKeys) ...[
                  const SizedBox(height: 8),
                  Pill(
                    label: 'DEV KEYS',
                    icon: Icons.science_rounded,
                    background: context.campus.warning,
                    foreground: context.campus.onWarning,
                    compact: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The switch at the top of the screen. **Verify** (the default) only checks a pass. **Out pass** also records
/// each valid pass as an exit, so the guard turns it on while students are going out and off again after.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final GateMode mode;
  final ValueChanged<GateMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.campus;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(999), border: Border.all(color: Colors.white24)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Segment(
            key: const ValueKey('mode-verify'),
            label: 'Verify',
            icon: Icons.verified_user_rounded,
            selected: mode == GateMode.verify,
            fill: Colors.white,
            ink: const Color(0xFF111827),
            onTap: () => onChanged(GateMode.verify),
          ),
          _Segment(
            key: const ValueKey('mode-outpass'),
            label: 'Out pass',
            icon: Icons.logout_rounded,
            selected: mode == GateMode.outPass,
            fill: colors.warning,
            ink: colors.onWarning,
            onTap: () => onChanged(GateMode.outPass),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({super.key, required this.label, required this.icon, required this.selected, required this.fill, required this.ink, required this.onTap});

  final String label;
  final IconData icon;
  final bool selected;
  final Color fill;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label mode',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(color: selected ? fill : Colors.transparent, borderRadius: BorderRadius.circular(999)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: selected ? ink : Colors.white70),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(color: selected ? ink : Colors.white70, fontSize: 13, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many exits are saved on this phone and not yet confirmed by the server.
class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.count, this.sync, this.onActivate, this.onOpenList});

  final int count;
  final SyncService? sync;
  final VoidCallback? onActivate;

  /// Opens today's out pass list (view only). The left half of the panel is the button.
  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, 18, 24, 18 + bottom),
      decoration: BoxDecoration(
        color: const Color(0xF2101828),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(CampusTheme.radiusCard)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24)],
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: onOpenList != null,
              label: "Today's out pass list",
              child: InkWell(
                key: const ValueKey('open-register'),
                onTap: onOpenList,
                borderRadius: BorderRadius.circular(16),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12)),
                      child: const Icon(Icons.fact_check_rounded, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$count', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.05)),
                          const Text('Saved on this phone', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        ],
                      ),
                    ),
                    if (onOpenList != null) const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                  ],
                ),
              ),
            ),
          ),
          if (sync != null) ...[
            const SizedBox(width: 10),
            _SyncPill(sync: sync!, onActivate: onActivate),
          ],
        ],
      ),
    );
  }
}

/// Where the saved scans stand with the server. Tap it to sync now.
class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.sync, this.onActivate});

  final SyncService sync;
  final VoidCallback? onActivate;

  static String _clock(int? unixS) {
    if (unixS == null) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(unixS * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return ' ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.campus;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final dim = Colors.white.withValues(alpha: 0.14);
        final (label, icon, background, foreground) = switch (sync.phase) {
          SyncPhase.notConfigured when onActivate != null => ('Activate', Icons.vpn_key_rounded, colors.warning, colors.onWarning),
          SyncPhase.notConfigured => ('Sync off', Icons.cloud_off_rounded, dim, Colors.white70),
          SyncPhase.idle => ('Waiting', Icons.cloud_queue_rounded, dim, Colors.white),
          SyncPhase.syncing => ('Syncing', null, dim, Colors.white),
          SyncPhase.synced => ('Synced${_clock(sync.lastSyncAtS)}', Icons.cloud_done_rounded, colors.success, colors.onSuccess),
          SyncPhase.offline => ('Offline', Icons.cloud_off_rounded, colors.warning, colors.onWarning),
          SyncPhase.unauthorized => ('Not authorised', Icons.lock_outline_rounded, colors.danger, colors.onDanger),
          SyncPhase.disabled => ('Disabled', Icons.block_rounded, colors.danger, colors.onDanger),
          SyncPhase.failed => ('Sync problem', Icons.error_outline_rounded, colors.danger, colors.onDanger),
        };
        // Not activated, or the token was refused: the way forward is to activate (again).
        final activates = onActivate != null && (sync.phase == SyncPhase.notConfigured || sync.phase == SyncPhase.unauthorized);
        final tappable = activates || (sync.client != null && sync.phase != SyncPhase.syncing);
        final pill = icon == null
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground)),
                    const SizedBox(width: 8),
                    Text(label, style: TextStyle(color: foreground, fontSize: 14, fontWeight: FontWeight.w700)),
                  ],
                ),
              )
            : Pill(label: label, icon: icon, background: background, foreground: foreground);
        return Semantics(
          button: tappable,
          label: 'Sync status: $label${tappable ? (activates ? '. Tap to activate this scanner' : '. Tap to sync now') : ''}',
          excludeSemantics: true,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: !tappable ? null : (activates ? onActivate : () => sync.syncNow()), child: pill),
        );
      },
    );
  }
}
