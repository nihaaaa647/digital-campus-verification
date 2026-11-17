import 'dart:async';

import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_controller.dart';
import 'id_card.dart';
import 'pass_controller.dart';
import 'photo_source.dart';

// The screens before the pass: sign in, details, waiting. They hold only what the student is typing; every
// rule and every call to the server is in HomeController.

/// The common page: centred, scrollable, no wider than a phone.
class _Frame extends StatelessWidget {
  const _Frame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const BrandMark(icon: Icons.badge_rounded, size: 40),
        const SizedBox(width: 12),
        Expanded(child: Text('Campus ID', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge)),
      ],
    );
  }
}

enum _Tone { info, warning, error }

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.tone = _Tone.info, this.icon});

  final String text;
  final _Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.campus;
    final (background, foreground, defaultIcon) = switch (tone) {
      _Tone.info => (scheme.secondaryContainer, scheme.onSecondaryContainer, Icons.info_outline_rounded),
      _Tone.warning => (colors.warning, colors.onWarning, Icons.schedule_rounded),
      _Tone.error => (scheme.errorContainer, scheme.onErrorContainer, Icons.error_outline_rounded),
    };
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(CampusTheme.radiusInner)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? defaultIcon, color: foreground, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: foreground, fontSize: 14, height: 1.35, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

/// A big round icon, a title and a sentence: the shape of every waiting or failing page.
class _Hero extends StatelessWidget {
  const _Hero({required this.icon, required this.title, required this.body, this.spinner = false, this.warn = false});

  final IconData icon;
  final String title;
  final String body;
  final bool spinner;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        Container(
          width: 104,
          height: 104,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: warn ? scheme.errorContainer : scheme.primaryContainer),
          child: spinner
              ? const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 4))
              : Icon(icon, size: 50, color: warn ? scheme.onErrorContainer : scheme.onPrimaryContainer),
        ),
        const SizedBox(height: 26),
        Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(body, style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
      ],
    );
  }
}

/// Shown while the app works out where the student is.
class StartingView extends StatelessWidget {
  const StartingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: BrandMark(icon: Icons.badge_rounded, size: 64)));
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5));
}

// --- sign in ---

/// The words for why there is no pass on this phone, when it is not simply the first run.
String? problemText(PassProblem? problem) => switch (problem) {
      null || PassProblem.notActivated => null,
      PassProblem.corrupt => 'Your pass data was damaged. Sign in again to get a new pass.',
      PassProblem.deviceKeyMissing || PassProblem.deviceKeyChanged => "This phone's security key is not the one your pass was issued to. Sign in again to register this phone.",
      PassProblem.expired => 'Your pass has expired. Sign in to renew it.',
      PassProblem.keystoreUnavailable => "The phone's key store did not answer. Restart the phone and open the app again.",
    };

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  late final _server = TextEditingController(text: widget.controller.server?.toString() ?? '');
  late bool _editingServer = widget.controller.server == null;
  String? _serverError;

  HomeController get c => widget.controller;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _saveServer() async {
    final error = await c.setServer(_server.text);
    if (!mounted) return;
    setState(() {
      _serverError = error;
      if (error == null) _editingServer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final sentTo = c.codeSentTo;
        final problem = c.notice == null ? problemText(c.problem) : null;
        return _Frame(
          children: [
            const _Brand(),
            const SizedBox(height: 36),
            Text('Sign in', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(sentTo == null ? 'Use your college email: your roll number followed by @vnrvjiet.in. We will send you a 6-digit code.' : 'We sent a 6-digit code to $sentTo.', style: muted),
            if (c.notice != null) _Banner(c.notice!, tone: _Tone.warning),
            if (problem != null) _Banner(problem, tone: _Tone.warning),
            const SizedBox(height: 20),
            if (sentTo == null) ..._emailStep(context) else ..._codeStep(context),
            if (c.error != null) _Banner(c.error!, tone: _Tone.error),
            const SizedBox(height: 28),
            _serverFooter(context),
            if (c.allowDemo) ..._demo(),
          ],
        );
      },
    );
  }

  List<Widget> _emailStep(BuildContext context) => [
        TextField(
          key: const ValueKey('email-field'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enabled: !c.busy,
          decoration: const InputDecoration(labelText: 'College email', hintText: '25071a66j1@vnrvjiet.in', prefixIcon: Icon(Icons.alternate_email_rounded)),
          onSubmitted: (_) => c.requestCode(_email.text),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: c.busy || c.server == null ? null : () => c.requestCode(_email.text),
          child: c.busy ? const _Busy() : const Text('Send code'),
        ),
      ];

  List<Widget> _codeStep(BuildContext context) {
    final devOtp = c.devOtp;
    return [
      if (devOtp != null)
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(CampusTheme.radiusInner)),
          child: Row(
            children: [
              Icon(Icons.science_rounded, color: Theme.of(context).colorScheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Demo mode: no email is sent. Your code is '),
                    TextSpan(text: devOtp, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
                  ]),
                  style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer, fontSize: 14, height: 1.35),
                ),
              ),
              TextButton(onPressed: () => _code.text = devOtp, child: const Text('Use it')),
            ],
          ),
        ),
      TextField(
        key: const ValueKey('code-field'),
        controller: _code,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        textInputAction: TextInputAction.done,
        enabled: !c.busy,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 26, letterSpacing: 8, fontWeight: FontWeight.w700),
        decoration: const InputDecoration(labelText: '6-digit code', counterText: '', prefixIcon: Icon(Icons.pin_rounded)),
        onSubmitted: (_) => c.verifyCode(_code.text),
      ),
      const SizedBox(height: 16),
      FilledButton(onPressed: c.busy ? null : () => c.verifyCode(_code.text), child: c.busy ? const _Busy() : const Text('Sign in')),
      const SizedBox(height: 4),
      // A Wrap, not a Row: on a narrow phone or at large text the second link drops to a line of its own.
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: c.busy
                ? null
                : () {
                    _code.clear();
                    c.useDifferentEmail();
                  },
            child: const Text('Use a different email'),
          ),
          TextButton(onPressed: c.busy ? null : () => c.requestCode(c.codeSentTo!), child: const Text('Send a new code')),
        ],
      ),
    ];
  }

  Widget _serverFooter(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (!_editingServer) {
      return Row(
        children: [
          Icon(Icons.dns_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(c.server.toString(), style: muted, overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: () => setState(() => _editingServer = true), child: const Text('Change')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('server-field'),
          controller: _server,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(labelText: 'College server address', helperText: 'Ask the college office if you are not sure.', errorText: _serverError, prefixIcon: const Icon(Icons.dns_rounded)),
          onSubmitted: (_) => _saveServer(),
        ),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: _saveServer, child: const Text('Use this server'))),
      ],
    );
  }

  List<Widget> _demo() => [
        const SizedBox(height: 12),
        if (c.problem == PassProblem.notActivated)
          OutlinedButton.icon(onPressed: c.createDemoPass, icon: const Icon(Icons.science_rounded), label: const Text('Create demo pass (debug build)'))
        else
          OutlinedButton.icon(onPressed: c.signOut, icon: const Icon(Icons.restart_alt_rounded), label: const Text('Reset this phone (debug build)')),
      ];
}

// --- details ---

class DetailsScreen extends StatefulWidget {
  const DetailsScreen({super.key, required this.controller, required this.photos, required this.cards});

  final HomeController controller;
  final PhotoSource photos;

  /// Reads name, branch and year off the college ID card.
  final CardReader cards;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _branch = TextEditingController();
  int _year = 1;
  Uint8List? _photo;
  String? _photoError;
  bool _picking = false;

  // The ID card: what was read off it, and why it was not usable.
  bool _scanned = false;
  bool _cardBusy = false;
  String? _cardNote;
  String? _cardProblem;

  HomeController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _phone.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
    _branch.addListener(() => setState(() {}));
    // The roll number gives the year of admission, so the year of study can be filled in before any scan.
    final roll = c.student?.rollNumber ?? '';
    final admitted = roll.length >= 2 ? int.tryParse(roll.substring(0, 2)) : null;
    if (admitted != null) _year = yearOfStudy(2000 + admitted, DateTime.now(), lateralEntry: roll.length > 5 && roll[5] == 'D');
  }

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _branch.dispose();
    super.dispose();
  }

  Future<void> _pick(PhotoOrigin origin) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _photoError = null;
    });
    try {
      final bytes = await widget.photos.take(origin);
      if (!mounted) return;
      setState(() {
        if (bytes != null) _photo = bytes;
      });
    } on PhotoException catch (e) {
      if (mounted) setState(() => _photoError = "Couldn't get a photo (${e.message}). Allow the camera for this app, or choose one from the gallery.");
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _scanCard(PhotoOrigin origin) async {
    if (_cardBusy) return;
    setState(() {
      _cardBusy = true;
      _cardProblem = null;
    });
    try {
      final card = await widget.cards.read(origin);
      if (!mounted || card == null) return;
      final mine = c.student?.rollNumber;
      setState(() {
        _scanned = true;
        if (card.rollNumber != null && mine != null && card.rollNumber != mine) {
          // Someone else's card: nothing from it is used.
          _cardProblem = 'This card is for ${card.rollNumber}, but you signed in as $mine. Scan your own ID card.';
          _cardNote = null;
          return;
        }
        if (card.name != null) _name.text = card.name!;
        if (card.branch != null) _branch.text = card.branch!;
        if (card.year != null) _year = card.year!;
        _cardNote = card.foundAnything
            ? 'Read from your card${card.rollNumber != null ? ' (${card.rollNumber})' : ''}. Check that it is right and correct anything that is not.'
            : "Couldn't read much from the card. Try again in better light, or type your details.";
      });
    } on PhotoException catch (e) {
      if (mounted) setState(() => _cardProblem = "Couldn't read the card (${e.message}). Allow the camera for this app, or choose a photo from the gallery.");
    } finally {
      if (mounted) setState(() => _cardBusy = false);
    }
  }

  bool get _profileOk => c.profileComplete || (_name.text.trim().isNotEmpty && _branch.text.trim().isNotEmpty && _cardProblem == null);

  bool get _ready => normalizePhone(_phone.text) != null && _photo != null && _profileOk;

  Widget _cardSection(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CampusTheme.radiusInner),
            border: Border.all(color: scheme.outlineVariant),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.badge_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Scan your college ID card', style: theme.textTheme.titleMedium)),
                ],
              ),
              const SizedBox(height: 6),
              Text('We read your name, branch and year off the card. The photo of the card stays on this phone.', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _cardBusy || c.busy ? null : () => _scanCard(PhotoOrigin.camera),
                    icon: _cardBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Icon(Icons.document_scanner_rounded),
                    label: Text(_scanned ? 'Scan again' : 'Scan ID card'),
                  ),
                  TextButton(onPressed: _cardBusy || c.busy ? null : () => _scanCard(PhotoOrigin.gallery), child: const Text('From gallery')),
                ],
              ),
            ],
          ),
        ),
        if (_cardProblem != null) _Banner(_cardProblem!, tone: _Tone.error),
        if (_cardNote != null && _cardProblem == null) _Banner(_cardNote!, icon: Icons.check_circle_outline_rounded),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('name-field'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          enabled: !c.busy,
          decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline_rounded)),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                key: const ValueKey('branch-field'),
                controller: _branch,
                textCapitalization: TextCapitalization.characters,
                maxLength: 12,
                enabled: !c.busy,
                decoration: const InputDecoration(labelText: 'Branch', counterText: '', prefixIcon: Icon(Icons.school_outlined)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<int>(
                key: const ValueKey('year-field'),
                initialValue: _year,
                decoration: const InputDecoration(labelText: 'Year'),
                items: [for (var y = 1; y <= 6; y++) DropdownMenuItem(value: y, child: Text('$y'))],
                onChanged: c.busy ? null : (y) => setState(() => _year = y ?? _year),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final student = c.student;
        return _Frame(
          children: [
            const _Brand(),
            const SizedBox(height: 28),
            if (student != null)
              Row(
                children: [
                  // A student the roster did not list has only a roll number so far: name, branch and year come from the card.
                  if (c.profileComplete)
                    InitialsAvatar(name: student.name, size: 52)
                  else
                    CircleAvatar(radius: 26, backgroundColor: scheme.primaryContainer, child: Icon(Icons.person_rounded, color: scheme.onPrimaryContainer)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.profileComplete ? student.name : student.rollNumber, style: theme.textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(c.profileComplete ? '${student.rollNumber} · ${student.branch} · Year ${student.year}' : 'Signed in as ${student.email}', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            Text('One more step', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(c.profileComplete ? 'Add your phone number and a clear photo of your face to get your pass.' : 'Scan your ID card, then add your phone number and a clear photo of your face to get your pass.', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            if (c.notice != null) _Banner(c.notice!, tone: _Tone.warning),
            const SizedBox(height: 22),
            if (!c.profileComplete) _cardSection(context),
            Center(
              child: Container(
                width: 148,
                height: 148,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest, border: Border.all(color: scheme.outlineVariant, width: 2)),
                child: _photo == null
                    ? Icon(Icons.face_rounded, size: 72, color: scheme.onSurfaceVariant)
                    : Image.memory(_photo!, key: const ValueKey('photo-preview'), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (context, error, stack) => Icon(Icons.broken_image_rounded, size: 56, color: scheme.error)),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _picking || c.busy ? null : () => _pick(PhotoOrigin.camera),
                  icon: const Icon(Icons.photo_camera_rounded),
                  label: Text(_photo == null ? 'Take photo' : 'Retake'),
                ),
                TextButton(onPressed: _picking || c.busy ? null : () => _pick(PhotoOrigin.gallery), child: const Text('Choose from gallery')),
              ],
            ),
            if (_photoError != null) _Banner(_photoError!, tone: _Tone.error),
            const SizedBox(height: 22),
            TextField(
              key: const ValueKey('phone-field'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              enabled: !c.busy,
              decoration: const InputDecoration(labelText: 'Mobile number', hintText: '+91 98765 43210', prefixIcon: Icon(Icons.phone_rounded)),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _ready && !c.busy ? () => c.submitDetails(phone: _phone.text, photo: _photo!, name: _name.text, branch: _branch.text, year: _year) : null,
              child: c.busy ? const _Busy() : Text(c.profileComplete ? 'Send for approval' : 'Get my pass'),
            ),
            if (c.error != null) _Banner(c.error!, tone: _Tone.error),
            const SizedBox(height: 8),
            TextButton(onPressed: c.busy ? null : c.signOut, child: const Text('Sign out')),
          ],
        );
      },
    );
  }
}

// --- waiting ---

class PendingScreen extends StatefulWidget {
  const PendingScreen({super.key, required this.controller, this.pollEvery = const Duration(seconds: 4)});

  final HomeController controller;

  /// How often to ask the server whether an admin has decided.
  final Duration pollEvery;

  @override
  State<PendingScreen> createState() => _PendingScreenState();
}

class _PendingScreenState extends State<PendingScreen> with WidgetsBindingObserver {
  Timer? _timer;

  HomeController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(widget.pollEvery, (_) => c.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final student = c.student;
        return _Frame(
          children: [
            const _Hero(
              icon: Icons.hourglass_top_rounded,
              title: 'Waiting for approval',
              body: 'The college is checking your details. This page updates by itself, so you can close the app and come back.',
            ),
            if (student != null) ...[
              const SizedBox(height: 22),
              Center(child: Pill(label: '${student.name} · ${student.rollNumber}', icon: Icons.person_rounded)),
            ],
            if (c.checkFailed) _Banner("Can't reach the college server right now. Still trying.", tone: _Tone.warning, icon: Icons.cloud_off_rounded),
            const SizedBox(height: 26),
            OutlinedButton.icon(onPressed: () => c.refresh(), icon: const Icon(Icons.refresh_rounded), label: const Text('Check now')),
            const SizedBox(height: 4),
            TextButton(onPressed: c.signOut, child: Text('Sign out', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))),
          ],
        );
      },
    );
  }
}

/// Between "approved" and the pass: the phone makes its key and the college signs it. Usually a second.
class ActivatingView extends StatelessWidget {
  const ActivatingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const _Frame(
      children: [
        _Hero(icon: Icons.badge_rounded, title: 'Getting your pass', body: 'Making a key on this phone and having the college sign it.', spinner: true),
      ],
    );
  }
}

/// The server could not be reached, or said something the app cannot act on.
class OfflineView extends StatelessWidget {
  const OfflineView({super.key, required this.controller});

  final HomeController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _Frame(
        children: [
          _Hero(icon: Icons.cloud_off_rounded, title: "Couldn't get your pass", body: controller.error ?? 'Something went wrong.', warn: true),
          const SizedBox(height: 28),
          FilledButton.icon(onPressed: controller.retry, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
          const SizedBox(height: 4),
          TextButton(onPressed: controller.signOut, child: const Text('Sign out')),
        ],
      ),
    );
  }
}
