import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_server.dart';
import 'vectors.dart';

/// A pretend project: `scanner-activate` swaps a code for a token (once), and `scanner-sync` accepts only
/// that token. Sync itself is [FakeServer], so rows are stored once and named back.
class FakeBackend {
  FakeBackend(Vectors vec) : keySet = Map<String, Object?>.from(vec.json['keyset_json'] as Map) {
    sync.serverTimeS = null;
  }

  final FakeServer sync = FakeServer();

  /// The key set the activation reply carries; null to leave it out.
  Map<String, Object?>? keySet;

  /// Codes that will still be accepted (normalised: capitals, no hyphen).
  final Set<String> validCodes = {'K7QM29XD'};

  /// The token the next activation hands out, and the only one sync accepts.
  String token = 'tok-${'A' * 40}';
  String scannerId = 'SC-NEW';
  String gate = 'North gate';
  int activateStatus = 200;
  Object? activateFailWith;

  final List<http.Request> activations = [];
  final List<Map<String, String>> syncHeaders = [];
  final List<Uri> syncUrls = [];

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/functions/v1/scanner-activate')) {
      activations.add(request);
      final failure = activateFailWith;
      if (failure != null) throw failure;
      if (activateStatus != 200) return http.Response('{}', activateStatus);
      final code = (jsonDecode(request.body) as Map)['code'];
      if (!validCodes.remove(code)) return http.Response('{"error":"invalid_or_expired_code"}', 404);
      return http.Response(
        jsonEncode({
          'scanner_id': scannerId,
          'name': 'New scanner',
          'gate': gate,
          'token': token,
          'keyset': keySet,
          'revocation_list': null,
          'guards': <Object?>[],
          'server_time': 1793118000,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/functions/v1/scanner-sync')) {
      syncUrls.add(request.url);
      syncHeaders.add(request.headers);
      if (request.headers['Authorization'] != 'Bearer $token') return http.Response('{}', 401);
      return sync.client.post(request.url, headers: request.headers, body: request.body);
    }
    return http.Response('not found', 404);
  });
}
