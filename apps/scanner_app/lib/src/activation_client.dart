import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why activation did not work. None of them leaves anything behind on the phone.
enum ActivationFailure {
  /// 404: the code is wrong, expired, already used, or not even shaped like a code.
  invalidCode,

  /// 403: the admin has disabled this scanner.
  disabled,

  /// No connection, a timeout, or nothing at that address.
  network,

  /// 5xx or 429.
  server,

  /// The server answered, but not in the shape of the contract (usually the wrong address).
  badResponse,
}

class ActivationException implements Exception {
  const ActivationException(this.failure, [this.detail = '']);

  final ActivationFailure failure;
  final String detail;

  @override
  String toString() => 'ActivationException(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// What `scanner-activate` returns (supabase/functions/_shared/scanner_activate.ts).
class ActivationReply {
  const ActivationReply({required this.scannerId, required this.name, required this.gate, required this.token, this.keySet, this.serverTimeS});

  final String scannerId;
  final String name;
  final String gate;

  /// The scanner's own token, shown once: keep it, it cannot be fetched again.
  final String token;

  /// The college public key set (docs/credential-spec.md section 8), or null if the server has none set up.
  final Map<String, Object?>? keySet;
  final int? serverTimeS;
}

/// The characters an activation code is made of (the server leaves out 0, 1, I and O).
const String _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Reads what a person typed as a code: upper case, no spaces or hyphens. Null if it cannot be a code.
String? normalizeActivationCode(String input) {
  final code = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (code.length != 8) return null;
  for (final ch in code.split('')) {
    if (!_codeAlphabet.contains(ch)) return null;
  }
  return code;
}

/// Turns what a person typed as a server address into the project's base address, or null if it is not one.
/// `xyz.supabase.co` becomes `https://xyz.supabase.co`; a trailing slash is dropped. `http://` is accepted
/// only when [allowInsecure] is set (development): Android blocks it in release builds anyway.
Uri? parseServerAddress(String input, {bool allowInsecure = false}) {
  var text = input.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http')) return null;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return null;
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return uri.replace(path: path);
}

/// Swaps an activation code for the scanner's identity.
class ActivationClient {
  ActivationClient(this.serverBase, {http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// The project's base address, from [parseServerAddress].
  final Uri serverBase;
  final Duration timeout;
  final http.Client _http;
  final bool _ownsClient;

  Uri get activateUri => serverBase.replace(path: '${serverBase.path}/functions/v1/scanner-activate');
  Uri get syncUri => serverBase.replace(path: '${serverBase.path}/functions/v1/scanner-sync');

  Future<ActivationReply> activate(String code) async {
    final normalized = normalizeActivationCode(code);
    // A code that cannot be one is not worth a round trip, and the server would only say 404 too.
    if (normalized == null) throw const ActivationException(ActivationFailure.invalidCode, 'not shaped like a code');

    final http.Response response;
    try {
      response = await _http.post(activateUri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'code': normalized})).timeout(timeout);
    } on TimeoutException {
      throw const ActivationException(ActivationFailure.network, 'timed out');
    } on http.ClientException catch (e) {
      throw ActivationException(ActivationFailure.network, e.message);
    } on Exception catch (e) {
      throw ActivationException(ActivationFailure.network, e.toString());
    }

    final status = response.statusCode;
    if (status == 404) throw const ActivationException(ActivationFailure.invalidCode);
    if (status == 403) throw const ActivationException(ActivationFailure.disabled);
    if (status == 429 || status >= 500) throw ActivationException(ActivationFailure.server, 'HTTP $status');
    if (status != 200) throw ActivationException(ActivationFailure.badResponse, 'HTTP $status');

    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ActivationException(ActivationFailure.badResponse, 'reply is not JSON');
    }
    if (body is! Map<String, Object?>) throw const ActivationException(ActivationFailure.badResponse, 'reply is not an object');

    final Map<String, Object?> map = body; // (a local function would lose the type check above)
    String? text(String key) => map[key] is String && (map[key] as String).isNotEmpty ? map[key] as String : null;
    final scannerId = text('scanner_id');
    final name = text('name');
    final gate = text('gate');
    final token = text('token');
    if (scannerId == null || name == null || gate == null || token == null || token.length < 20) {
      throw const ActivationException(ActivationFailure.badResponse, 'scanner_id, name, gate or token missing');
    }
    final keySet = map['keyset'];
    final serverTime = map['server_time'];
    return ActivationReply(
      scannerId: scannerId,
      name: name,
      gate: gate,
      token: token,
      keySet: keySet is Map<String, Object?> ? keySet : null,
      serverTimeS: serverTime is int ? serverTime : null,
    );
  }

  /// Closes the connection if this client made it; a client passed in stays open for its owner.
  void close() {
    if (_ownsClient) _http.close();
  }
}
