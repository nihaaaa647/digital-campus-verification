import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scanner_app/src/scan_log.dart';

/// Stands in for `scanner-sync` as documented in supabase/functions/scanner-sync/index.ts: it stores
/// each scan once by `scan_id` (the `on conflict do nothing`) and names every id it holds.
class FakeServer {
  /// Everything it has stored, by scan id.
  final Map<String, Map<String, Object?>> received = {};

  /// The decoded body of every request, in order.
  final List<Map<String, Object?>> requests = [];
  final List<Map<String, String>> requestHeaders = [];

  /// A non-200 status makes it refuse without reading the body.
  int status = 200;

  /// When set, requests throw this instead of answering (no connection, timeout...).
  Object? failWith;

  /// Seconds to report as the server clock, or null to leave `server_time` out.
  int? serverTimeS = 1793118000;

  /// If set, only these scan ids are accepted; the rest are left out of the reply.
  Set<String>? acceptOnly;

  /// Extra ids to name in the reply even though the request did not carry them.
  List<String> extraAccepted = const [];

  /// Runs before the reply, so a test can look at the phone's log mid-request.
  Future<void> Function(Map<String, Object?> body)? onRequest;

  /// The server stores the rows, then the reply never reaches the phone (a dropped connection).
  bool loseReply = false;

  /// Replaces the body of a 200 reply (to test malformed replies).
  String? rawBody;

  int get calls => requests.length;

  late final http.Client client = MockClient((request) async {
    final failure = failWith;
    if (failure != null) throw failure;
    if (status != 200) return http.Response('{"error":"nope"}', status);
    final body = jsonDecode(request.body) as Map<String, Object?>;
    requests.add(body);
    requestHeaders.add(request.headers);
    await onRequest?.call(body);

    final accepted = <String>[];
    for (final scan in (body['scans'] as List).cast<Map<String, Object?>>()) {
      final id = scan['scan_id'] as String;
      if (acceptOnly != null && !acceptOnly!.contains(id)) continue;
      received.putIfAbsent(id, () => scan);
      accepted.add(id);
    }
    if (loseReply) throw const SocketException('connection reset before the reply');
    final reply = rawBody ??
        jsonEncode({
          'accepted_scan_ids': [...accepted, ...extraAccepted],
          if (serverTimeS != null) 'server_time': serverTimeS,
          'keyset': {'v': 1, 'current': 2, 'keys': <Object?>[]}, // present in the real reply; not read yet
          'revocation_list': null,
          'guards': <Object?>[],
        });
    return http.Response(reply, 200, headers: {'content-type': 'application/json'});
  });
}

/// A row with fixed content apart from [id] and [at].
ScanRecord row(String id, {int at = 1793118000, int? sid = 1042, String? roll = '25071A0001', EntryMethod method = EntryMethod.scan}) {
  return ScanRecord(scanId: id, scannedAt: at, studentId: sid, rollNumber: roll, gate: 'Main', guardId: 'G-03', entryMethod: method);
}

/// `00000007-0000-4000-8000-000000000000`: valid-looking ids that sort in the order of [n].
String idOf(int n) => '${n.toString().padLeft(8, '0')}-0000-4000-8000-000000000000';
