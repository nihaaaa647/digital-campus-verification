import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'scan_log.dart';

/// Where the scanner syncs to and the token it proves itself with. Activation (`scanner-activate`) will
/// hand these out; until it exists they come from build-time settings (see main.dart).
class SyncConfig {
  const SyncConfig({required this.endpoint, required this.token});

  /// The `scanner-sync` function URL.
  final Uri endpoint;

  /// The scanner token (`Authorization: Bearer ...`).
  final String token;

  /// Null when [url] is empty, meaning this build is not set up to sync.
  static SyncConfig? tryParse(String url, String token) {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return SyncConfig(endpoint: uri, token: token);
  }
}

/// Why a sync attempt did not finish. Every kind leaves the log untouched.
enum SyncFailure {
  /// No connection, a timeout, or the server could not be reached.
  network,

  /// 401: the token is not recognised.
  unauthorized,

  /// 403: the admin has disabled this scanner.
  disabled,

  /// 5xx or 429: the server is having trouble; try again later.
  server,

  /// The server answered, but not in the shape of the contract, or it refused the request (other 4xx).
  badResponse,

  /// The server accepted none of the rows it was sent.
  noProgress,
}

class SyncException implements Exception {
  const SyncException(this.failure, [this.detail = '']);

  final SyncFailure failure;
  final String detail;

  @override
  String toString() => 'SyncException(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// What the server confirmed.
class SyncResponse {
  const SyncResponse({required this.acceptedScanIds, this.serverTimeS});

  /// Every `scan_id` the server now holds, including ones it already had. Only these may be deleted.
  final Set<String> acceptedScanIds;

  /// Server clock, unix seconds (PRD G14). The key set, revocation list and guards in the same reply are
  /// not read yet (G10).
  final int? serverTimeS;
}

/// One round trip to `scanner-sync`: the request and response documented at the top of
/// supabase/functions/scanner-sync/index.ts.
class SyncClient {
  SyncClient(this.config, {http.Client? httpClient, this.timeout = const Duration(seconds: 20)}) : _http = httpClient ?? http.Client();

  final SyncConfig config;
  final Duration timeout;
  final http.Client _http;

  /// `2026-11-03T07:32:14Z`, which Postgres reads as `timestamptz`.
  static String isoUtc(int unixS) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixS * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:${two(d.second)}Z';
  }

  static Map<String, Object?> scanJson(ScanRecord r) => {
        'scan_id': r.scanId,
        'scanned_at': isoUtc(r.scannedAt),
        'student_id': r.studentId,
        'roll_number': r.rollNumber,
        'type': r.type.wire,
        'gate': r.gate,
        'guard_id': r.guardId,
        'entry_method': r.entryMethod.wire,
      };

  /// Sends [scans] (possibly none, to just exchange the clock) and returns what the server confirmed.
  /// Throws [SyncException]; nothing here deletes anything.
  Future<SyncResponse> sync(List<ScanRecord> scans) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            config.endpoint,
            headers: {'Authorization': 'Bearer ${config.token}', 'Content-Type': 'application/json'},
            body: jsonEncode({'scans': [for (final s in scans) scanJson(s)], 'visitors': <Object?>[]}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const SyncException(SyncFailure.network, 'timed out');
    } on http.ClientException catch (e) {
      throw SyncException(SyncFailure.network, e.message);
    } on Exception catch (e) {
      // SocketException, HandshakeException and friends: all "could not reach the server".
      throw SyncException(SyncFailure.network, e.toString());
    }

    final code = response.statusCode;
    if (code == 401) throw const SyncException(SyncFailure.unauthorized);
    if (code == 403) throw const SyncException(SyncFailure.disabled);
    if (code == 429 || code >= 500) throw SyncException(SyncFailure.server, 'HTTP $code');
    if (code != 200) throw SyncException(SyncFailure.badResponse, 'HTTP $code');

    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SyncException(SyncFailure.badResponse, 'reply is not JSON');
    }
    if (body is! Map<String, Object?>) throw const SyncException(SyncFailure.badResponse, 'reply is not an object');
    final accepted = body['accepted_scan_ids'];
    if (accepted is! List || accepted.any((id) => id is! String)) {
      throw const SyncException(SyncFailure.badResponse, 'accepted_scan_ids missing or malformed');
    }
    final serverTime = body['server_time'];
    return SyncResponse(
      acceptedScanIds: {for (final id in accepted) id as String},
      serverTimeS: serverTime is int ? serverTime : null,
    );
  }

  void close() => _http.close();
}
