import 'dart:async';

import 'package:flutter/foundation.dart';

import 'scan_log.dart';
import 'sync_client.dart';

/// Where the scanner stands with the server, for the guard's status pill.
enum SyncPhase {
  /// This build has no sync address, so scans stay on the phone.
  notConfigured,

  /// Set up, nothing attempted yet.
  idle,
  syncing,

  /// The last attempt worked.
  synced,

  /// No connection, or the server is having trouble. Retried by itself.
  offline,

  /// The server does not recognise this scanner's token.
  unauthorized,

  /// The admin has disabled this scanner.
  disabled,

  /// The server answered but refused the rows or sent something unusable.
  failed,
}

/// Sends the saved scans to the server and deletes the ones it confirms (PRD G9, G14).
///
/// A row leaves the phone only when the server names its `scan_id` in `accepted_scan_ids`, so a lost
/// reply or a half-finished batch just means the same rows are sent again, and the server ignores
/// repeats. A row stays until the server says it has it.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.log,
    required this.state,
    required this.client,
    int Function()? phoneNowMs,
    this.batchSize = 100,
    this.pokeDelay = const Duration(seconds: 2),
    this.idleInterval = const Duration(minutes: 5),
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(minutes: 15),
    this.onPending,
    this.onServerOffset,
  })  : _phoneNowMs = phoneNowMs ?? _systemNowMs,
        phase = client == null ? SyncPhase.notConfigured : SyncPhase.idle;

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  final ScanLog log;
  final SyncStateStore state;

  /// Null when this build is not set up to sync.
  final SyncClient? client;
  final int batchSize;

  /// How long after a new scan (or a tap) before syncing, so a burst of scans goes in one request.
  final Duration pokeDelay;

  /// How often to sync when all is well, to keep the clock offset fresh and pick up server changes.
  final Duration idleInterval;

  /// First retry delay after a failure; it doubles each time up to [maxDelay].
  final Duration baseDelay;
  final Duration maxDelay;

  /// Told how many rows are still on the phone after each change.
  final void Function(int pending)? onPending;

  /// Told the new server-time offset (server minus phone, seconds) after each sync.
  final void Function(int offsetS)? onServerOffset;
  final int Function() _phoneNowMs;

  SyncPhase phase;
  SyncFailure? lastFailure;

  /// Rows on the phone not yet confirmed by the server.
  int pending = 0;

  /// Scanner clock, unix seconds, of the last time the server answered.
  int? lastSyncAtS;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  int _failures = 0;

  /// Reads the saved state. Call once before [start].
  Future<void> load() async {
    pending = await log.count();
    lastSyncAtS = await state.lastSyncAtS();
    _notify();
  }

  /// Begins syncing: soon, then regularly.
  void start() {
    if (client != null) _schedule(pokeDelay);
  }

  /// A scan was just saved: sync shortly.
  void poke() {
    if (client == null || _disposed) return;
    if (!_running) _schedule(pokeDelay);
  }

  /// The count changed outside a sync (a scan was saved).
  void setPending(int value) {
    pending = value;
    _notify();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(delay, () => unawaited(syncNow()));
  }

  /// One full pass: send every saved row in batches until none is left, or something goes wrong. Safe to
  /// call at any time; a pass already running is not doubled.
  Future<void> syncNow() async {
    final c = client;
    if (c == null || _running || _disposed) return;
    _running = true;
    _timer?.cancel();
    phase = SyncPhase.syncing;
    _notify();

    try {
      var first = true;
      while (true) {
        final batch = await log.oldest(batchSize);
        if (batch.isEmpty && !first) break;
        first = false; // even with nothing to send, one request exchanges the clock

        final sentMs = _phoneNowMs();
        final reply = await c.sync(batch);
        final receivedMs = _phoneNowMs();

        final serverTime = reply.serverTimeS;
        if (serverTime != null) {
          // The server's second is truncated, so the true time is half a second later on average; the reply
          // took half the round trip to arrive.
          final midMs = (sentMs + receivedMs) / 2;
          final offset = (((serverTime + 0.5) * 1000 - midMs) / 1000).round();
          await state.saveSync(serverOffsetS: offset, syncedAtS: receivedMs ~/ 1000);
          lastSyncAtS = receivedMs ~/ 1000;
          onServerOffset?.call(offset);
        }

        if (batch.isEmpty) break;
        // Delete only what the server confirmed, and only what was in this batch.
        final sent = {for (final r in batch) r.scanId};
        final confirmed = reply.acceptedScanIds.where(sent.contains).toList();
        if (confirmed.isEmpty) throw const SyncException(SyncFailure.noProgress, 'the server accepted none of the rows sent');
        await log.remove(confirmed);
        pending = await log.count();
        onPending?.call(pending);
        _notify();
      }

      pending = await log.count();
      onPending?.call(pending);
      _failures = 0;
      lastFailure = null;
      phase = SyncPhase.synced;
      _schedule(idleInterval);
    } on SyncException catch (e) {
      lastFailure = e.failure;
      phase = switch (e.failure) {
        SyncFailure.network || SyncFailure.server => SyncPhase.offline,
        SyncFailure.unauthorized => SyncPhase.unauthorized,
        SyncFailure.disabled => SyncPhase.disabled,
        SyncFailure.badResponse || SyncFailure.noProgress => SyncPhase.failed,
      };
      _failures++;
      // A wrong token or a disabled scanner will not fix itself in seconds: wait the longest.
      final patient = e.failure == SyncFailure.unauthorized || e.failure == SyncFailure.disabled;
      _schedule(patient ? maxDelay : _backoff());
      if (kDebugMode) debugPrint('sync: $e');
    } catch (e) {
      // A local problem (the log could not be read or written). Nothing was lost; try again later.
      lastFailure = SyncFailure.badResponse;
      phase = SyncPhase.failed;
      _failures++;
      _schedule(_backoff());
      if (kDebugMode) debugPrint('sync: local error: $e');
    } finally {
      _running = false;
      _notify();
    }
  }

  Duration _backoff() {
    final factor = 1 << (_failures - 1).clamp(0, 10);
    final delay = baseDelay * factor;
    return delay > maxDelay ? maxDelay : delay;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    client?.close();
    super.dispose();
  }
}
