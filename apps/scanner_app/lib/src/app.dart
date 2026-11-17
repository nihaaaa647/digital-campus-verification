import 'package:campus_ui/campus_ui.dart';
import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'activation_screen.dart';
import 'activator.dart';
import 'camera_view.dart';
import 'gate_controller.dart';
import 'key_set.dart';
import 'outpass_screen.dart';
import 'scan_log.dart';
import 'scan_screen.dart';
import 'scanner_identity.dart';
import 'sync_client.dart';
import 'sync_service.dart';

/// Opens the scan log. Tests pass an in-memory one.
typedef ScanLogOpener = Future<SqliteScanLog> Function();

class ScannerApp extends StatelessWidget {
  const ScannerApp({
    super.key,
    this.keySetSource,
    this.cameraBuilder = defaultCameraBuilder,
    this.openLog = SqliteScanLog.openInAppStorage,
    this.identityStore,
    this.syncConfig,
    this.defaultServer = '',
    this.allowInsecure = kDebugMode,
    this.httpClient,
    this.syncPokeDelay = const Duration(seconds: 2),
    this.phoneNowS,
  });

  /// The PUBLIC test key set, for development builds. Used only when the scanner has no keys of its own
  /// from activation; the scan screen then says DEV KEYS. Null in a real build.
  final KeySetSource? keySetSource;
  final CameraBuilder cameraBuilder;
  final ScanLogOpener openLog;

  /// Where the scanner's token is kept. Null means Android's encrypted storage.
  final IdentityStore? identityStore;

  /// A fixed sync address and token from the build, for development. It replaces activation: a scanner
  /// built with it syncs as that scanner without being activated.
  final SyncConfig? syncConfig;

  /// Prefills the server address on the activation screen.
  final String defaultServer;

  /// Accept `http://` server addresses (development only).
  final bool allowInsecure;

  /// The HTTP client for activation and sync; tests replace it.
  final http.Client? httpClient;
  final Duration syncPokeDelay;

  /// The phone's clock in unix seconds; tests replace it.
  final int Function()? phoneNowS;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Campus Gate',
      // Always dark: the camera fills the screen, and a bright app around it would glare at the guard.
      theme: CampusTheme.dark(),
      themeMode: ThemeMode.dark,
      home: ScannerHome(
        devKeySource: keySetSource,
        cameraBuilder: cameraBuilder,
        openLog: openLog,
        identityStore: identityStore,
        syncConfig: syncConfig,
        defaultServer: defaultServer,
        allowInsecure: allowInsecure,
        httpClient: httpClient,
        syncPokeDelay: syncPokeDelay,
        phoneNowS: phoneNowS,
      ),
    );
  }
}

/// Decides what the guard sees: the scan screen when the scanner has college keys and a log, the
/// activation screen when it has no keys (it cannot tell a real pass from a forged one), or an explanation
/// when it cannot start. Keys come from activation; a development build can fall back to the test keys.
class ScannerHome extends StatefulWidget {
  const ScannerHome({
    super.key,
    required this.devKeySource,
    required this.cameraBuilder,
    required this.openLog,
    this.identityStore,
    this.syncConfig,
    this.defaultServer = '',
    this.allowInsecure = false,
    this.httpClient,
    this.syncPokeDelay = const Duration(seconds: 2),
    this.phoneNowS,
  });

  final KeySetSource? devKeySource;
  final CameraBuilder cameraBuilder;
  final ScanLogOpener openLog;
  final IdentityStore? identityStore;
  final SyncConfig? syncConfig;
  final String defaultServer;
  final bool allowInsecure;
  final http.Client? httpClient;
  final Duration syncPokeDelay;
  final int Function()? phoneNowS;

  @override
  State<ScannerHome> createState() => _ScannerHomeState();
}

/// The gate and the sync that serves it, which feed each other: a saved scan starts a sync, and a finished
/// sync updates the saved count and the clock offset.
class _Kit {
  const _Kit(this.gate, this.sync, {required this.devKeys, required this.register});

  final GateController gate;
  final SyncService sync;

  /// The scanner is using the public test keys, not keys from its server.
  final bool devKeys;

  /// The out pass register, shown from the scan screen.
  final OutpassRegister register;
}

class _ScannerHomeState extends State<ScannerHome> {
  late final IdentityStore _identities = widget.identityStore ?? SecureIdentityStore();
  SqliteScanLog? _log;
  _Kit? _kit;
  Object? _error;
  bool _loading = true;
  bool _activating = false;

  /// The scanner has college keys, so it can go back to scanning if the guard leaves the activation form.
  bool _hasKeys = false;
  String _server = '';

  @override
  void initState() {
    super.initState();
    _server = widget.defaultServer;
    _start();
  }

  Future<void> _start() async {
    _kit?.sync.dispose();
    _kit = null;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final log = _log ??= await widget.openLog();
      // If the encrypted storage cannot be read (a restored backup, a wiped key), the scanner is simply not activated.
      ScannerIdentity? identity;
      try {
        identity = await _identities.load();
      } catch (_) {
        identity = null;
      }
      if (identity != null) _server = identity.serverBase.toString();

      // Keys from the server win; the public test keys are only a development fallback.
      Map<int, Uint8List>? keys;
      var devKeys = false;
      final stored = await log.storedKeySet();
      if (stored != null) {
        try {
          keys = parseKeySet(stored);
        } on FormatException {
          keys = null; // damaged: as good as absent
        }
      }
      if (keys == null && widget.devKeySource != null) {
        keys = await widget.devKeySource!.load();
        devKeys = true;
      }

      _hasKeys = keys != null;
      if (keys == null) {
        _kit = null; // nothing to scan with: activation is the only way forward
      } else {
        _kit = await _buildKit(log, keys, identity, devKeys);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _activating = keys == null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<_Kit> _buildKit(SqliteScanLog log, Map<int, Uint8List> keys, ScannerIdentity? identity, bool devKeys) async {
    final config = widget.syncConfig ?? identity?.syncConfig;
    final nowS = widget.phoneNowS;

    late final GateController gate;
    final sync = SyncService(
      log: log,
      state: log,
      client: config == null ? null : SyncClient(config, httpClient: widget.httpClient),
      phoneNowMs: nowS == null ? null : () => nowS() * 1000,
      pokeDelay: widget.syncPokeDelay,
      onPending: (n) => gate.setSavedCount(n),
      onServerOffset: (offset) => gate.setServerOffset(offset),
    );
    gate = GateController(
      keys: keys,
      log: log,
      // The gate the server says this scanner guards; the guard stays the placeholder until guard login exists.
      context: GateContext(gate: identity?.gate ?? devGateContext.gate, guardId: devGateContext.guardId),
      savedCount: await log.count(),
      serverOffsetS: await log.serverOffsetS(),
      onSaved: sync.poke,
      phoneNowS: nowS,
    );
    await sync.load();
    sync.start();
    return _Kit(gate, sync, devKeys: devKeys, register: log);
  }

  Future<String?> _activate(String server, String code) async {
    final log = _log;
    if (log == null) return saveFailedMessage;
    final result = await Activator(identityStore: _identities, keyStore: log, httpClient: widget.httpClient, allowInsecure: widget.allowInsecure)
        .activate(server: server, code: code);
    switch (result) {
      case Activated():
        await _start(); // picks up the new identity and keys, and goes to the scan screen
        return null;
      case ActivationFailed(:final message):
        return message;
    }
  }

  void _openActivation() {
    _kit?.sync.dispose();
    _kit = null;
    setState(() => _activating = true);
  }

  @override
  void dispose() {
    _kit?.sync.dispose();
    _log?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const _CannotStart(
        title: "The scanner can't start",
        body: 'Its scan log could not be opened, so it cannot record passes. '
            'Restart the app. If it repeats, reinstall it, and log exits by hand meanwhile.',
      );
    }
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final kit = _kit;
    if (_activating || kit == null) {
      return ActivationScreen(
        initialServer: _server,
        onSubmit: _activate,
        notice: _hasKeys ? null : 'This scanner has no college keys yet, so it cannot check passes. Ask the admin for a one-time code for this gate.',
        onCancel: _hasKeys ? _start : null, // back to scanning with what it already has
      );
    }
    return ScanScreen(
      controller: kit.gate,
      sync: kit.sync,
      cameraBuilder: widget.cameraBuilder,
      devKeys: kit.devKeys,
      onActivate: _openActivation,
      onOpenRegister: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OutpassScreen(register: kit.register, phoneNow: widget.phoneNowS == null ? null : () => DateTime.fromMillisecondsSinceEpoch(widget.phoneNowS!() * 1000)))),
    );
  }
}

class _CannotStart extends StatelessWidget {
  const _CannotStart({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.errorContainer),
                  child: Icon(Icons.error_outline_rounded, size: 46, color: theme.colorScheme.onErrorContainer),
                ),
                const SizedBox(height: 24),
                Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(body, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
