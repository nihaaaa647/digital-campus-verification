import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'home_controller.dart';
import 'id_card.dart';
import 'keystore_signer.dart';
import 'onboarding_screens.dart';
import 'pass_screen.dart';
import 'pass_store.dart';
import 'photo_source.dart';
import 'session_store.dart';
import 'student_api.dart';

class StudentApp extends StatefulWidget {
  const StudentApp({
    super.key,
    required this.store,
    required this.signer,
    this.sessions,
    this.photos,
    this.cards,
    this.apiFor,
    this.defaultServer,
    this.phoneNowS,
    this.allowDemo = kDebugMode,
    this.allowInsecure = kDebugMode,
    this.pollEvery = const Duration(seconds: 4),
  });

  /// Where the pass is kept.
  final PassStore store;
  final KeystoreSigner signer;

  /// Where the login is kept. Defaults to the phone's encrypted storage.
  final SessionStore? sessions;

  /// Where the enrolment photo comes from. Defaults to the phone's camera and gallery.
  final PhotoSource? photos;

  /// Reads the college ID card. Defaults to the phone's camera and on-device text recognition.
  final CardReader? cards;

  /// Makes the client for a server address. Tests replace it.
  final StudentApi Function(Uri base)? apiFor;

  /// The server to use until the student picks another (a build setting).
  final Uri? defaultServer;

  /// The phone's clock in unix seconds; tests replace it.
  final int Function()? phoneNowS;

  /// Offer the test-key demo pass when nothing is stored. Debug builds only.
  final bool allowDemo;

  /// Accept `http://` server addresses. Debug builds only: release builds must use https.
  final bool allowInsecure;

  /// How often the waiting screen asks whether the college has decided.
  final Duration pollEvery;

  @override
  State<StudentApp> createState() => _StudentAppState();
}

class _StudentAppState extends State<StudentApp> {
  late final HomeController _home = HomeController(
    sessions: widget.sessions ?? SecureSessionStore(),
    passes: widget.store,
    signer: widget.signer,
    apiFor: widget.apiFor ?? StudentApi.new,
    defaultServer: widget.defaultServer,
    allowInsecure: widget.allowInsecure,
    allowDemo: widget.allowDemo,
    phoneNowS: widget.phoneNowS,
  );
  late final PhotoSource _photos = widget.photos ?? DevicePhotoSource();
  late final CardReader _cards = widget.cards ?? DeviceCardReader();

  @override
  void initState() {
    super.initState();
    _home.start();
  }

  @override
  void dispose() {
    _home.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Campus ID',
      theme: CampusTheme.light(),
      darkTheme: CampusTheme.dark(),
      home: ListenableBuilder(
        listenable: _home,
        builder: (context, _) => switch (_home.stage) {
          Stage.starting => const StartingView(),
          Stage.signedOut => SignInScreen(controller: _home),
          Stage.details => DetailsScreen(controller: _home, photos: _photos, cards: _cards),
          Stage.pending => PendingScreen(controller: _home, pollEvery: widget.pollEvery),
          Stage.activating => const ActivatingView(),
          Stage.pass => PassScreen(key: ObjectKey(_home.pass), controller: _home.pass!, onSignOut: _home.signOut),
          Stage.offline => OfflineView(controller: _home),
        },
      ),
    );
  }
}
