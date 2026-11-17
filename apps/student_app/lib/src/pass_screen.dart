import 'package:campus_ui/campus_ui.dart';
import 'package:credential_core/credential_core.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'keystore_signer.dart';
import 'pass_controller.dart';

/// The exit pass: a QR that is re-signed every [PassController.refreshS] seconds, with a countdown.
/// The screen owns [controller] and disposes it.
class PassScreen extends StatefulWidget {
  const PassScreen({super.key, required this.controller, this.onSignOut});

  final PassController controller;

  /// Adds a menu with "Sign out" to the header when given.
  final VoidCallback? onSignOut;

  @override
  State<PassScreen> createState() => _PassScreenState();
}

class _PassScreenState extends State<PassScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers do not run while the app is in the background; sign a fresh QR the moment it is back.
    if (state == AppLifecycleState.resumed) widget.controller.tick();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(live: c.qr != null, onSignOut: widget.onSignOut),
                    const SizedBox(height: 16),
                    if (c.clockSuspect) _ClockWarning(offsetS: c.serverOffsetS),
                    _PassCard(controller: c),
                    const SizedBox(height: 16),
                    _Footer(controller: c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.live, this.onSignOut});

  final bool live;
  final VoidCallback? onSignOut;

  Future<void> _confirmSignOut(BuildContext context) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Your pass is removed from this phone. Sign in again to get it back.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (sure == true) onSignOut?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const BrandMark(icon: Icons.badge_rounded, size: 40),
        const SizedBox(width: 12),
        Expanded(child: Text('Campus ID', style: Theme.of(context).textTheme.titleLarge)),
        if (live) const _LivePill(),
        if (onSignOut != null)
          PopupMenuButton<String>(
            tooltip: 'Menu',
            onSelected: (_) => _confirmSignOut(context),
            itemBuilder: (context) => const [PopupMenuItem(value: 'sign-out', child: Text('Sign out'))],
          ),
      ],
    );
  }
}

/// A pulsing dot and "LIVE": a screenshot of a pass does not pulse, and a guard can see the difference.
class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) {
    final live = context.campus.live;
    return Semantics(
      label: 'Live pass',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
        decoration: BoxDecoration(color: live.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PulsingDot(color: live),
            const SizedBox(width: 8),
            Text('LIVE', style: TextStyle(color: live, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          ],
        ),
      ),
    );
  }
}

/// The QR, then who it belongs to. The QR is the biggest thing on the screen because it is what the
/// scanner reads.
class _PassCard extends StatelessWidget {
  const _PassCard({required this.controller});

  final PassController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final credential = controller.credential;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(CampusTheme.radiusCard),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 28, offset: const Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _QrPanel(controller: controller),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: _Countdown(controller: controller),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Divider(height: 1, color: scheme.outlineVariant),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _Identity(credential: credential),
          ),
        ],
      ),
    );
  }
}

class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.controller});

  final PassController controller;

  @override
  Widget build(BuildContext context) {
    final qr = controller.qr;
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        // Always black on white, whatever the app theme: scanners need the contrast and a quiet zone.
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CampusTheme.radiusInner + 2),
          border: Border.all(color: const Color(0xFFE3E7EF)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: qr == null
              ? _QrPlaceholder(fault: controller.fault)
              : QrImageView(
                  data: qr,
                  errorCorrectionLevel: QrErrorCorrectLevel.L, // spec section 6: fewer modules, faster scans
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  semanticsLabel: 'Exit pass QR code',
                ),
        ),
      ),
    );
  }
}

class _QrPlaceholder extends StatelessWidget {
  const _QrPlaceholder({required this.fault});

  final PassFault? fault;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (fault) {
      PassFault.expired => (Icons.event_busy_rounded, 'Pass expired', 'Connect to the internet to renew it.'),
      PassFault.signingFailed => (Icons.lock_clock_rounded, "Can't sign the pass", 'Trying again…'),
      null => (Icons.qr_code_2_rounded, 'Preparing your pass', 'One moment…'),
    };
    // The square is a fixed size, so shrink the message to fit it rather than overflow at large text sizes.
    return LayoutBuilder(
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: box.maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: const Color(0xFF5B6475)),
              const SizedBox(height: 14),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF111827), fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF5B6475), fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.controller});

  final PassController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.fault == PassFault.expired) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final left = controller.secondsLeft;
    final signing = controller.qr == null;
    final label = signing ? 'Signing…' : 'New code in $left s';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: signing ? 0 : left / controller.refreshS),
                  duration: const Duration(milliseconds: 900),
                  builder: (context, value, _) => CircularProgressIndicator(
                    value: signing ? null : value,
                    strokeWidth: 5,
                    strokeCap: StrokeCap.round,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                if (!signing) Text('$left', style: theme.textTheme.labelLarge),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleMedium),
                Text('Hold this up to the scanner', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.credential});

  final Credential credential;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pass = switch (credential.passType) {
      PassType.student => 'Student',
      PassType.fresher => 'Fresher',
      PassType.visitor => 'Visitor',
      null => 'Pass',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InitialsAvatar(name: credential.name, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(credential.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(height: 1.15)),
                  const SizedBox(height: 2),
                  Text(
                    '${credential.roll} · ${credential.branch} · Year ${credential.year}',
                    maxLines: 2,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill(label: pass, icon: Icons.verified_user_rounded),
            Pill(
              label: 'Valid until ${_date(credential.exp)}',
              icon: Icons.event_rounded,
              background: theme.colorScheme.surfaceContainerHighest,
              foreground: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final PassController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Text('The code changes every ${controller.refreshS} seconds, so a screenshot will not work.', textAlign: TextAlign.center, style: muted),
        if (controller.keySecurity == KeySecurity.software) ...[
          const SizedBox(height: 8),
          Text('This phone has no secure hardware for keys, so the pass key is held in software.', textAlign: TextAlign.center, style: muted),
        ],
      ],
    );
  }
}

class _ClockWarning extends StatelessWidget {
  const _ClockWarning({required this.offsetS});

  final int offsetS;

  @override
  Widget build(BuildContext context) {
    final colors = context.campus;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: colors.warning, borderRadius: BorderRadius.circular(CampusTheme.radiusInner)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule_rounded, color: colors.onWarning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "This phone's clock is ${offsetS.abs()} s ${offsetS > 0 ? 'behind' : 'ahead of'} the college server. "
              'The pass corrects for it, but connect to the internet to resync.',
              style: TextStyle(color: colors.onWarning, fontSize: 14, height: 1.35, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(int unixS) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixS * 1000);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}
