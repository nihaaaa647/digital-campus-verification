import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sync_client.dart';

/// Who this scanner is, as the server told it at activation. The token is a credential: it is what proves
/// to `scanner-sync` that these scans come from this scanner.
class ScannerIdentity {
  const ScannerIdentity({required this.serverBase, required this.scannerId, required this.name, required this.gate, required this.token});

  /// The project's base address, for example `https://xyz.supabase.co`.
  final Uri serverBase;
  final String scannerId;
  final String name;
  final String gate;
  final String token;

  Uri get syncEndpoint => serverBase.replace(path: '${serverBase.path}/functions/v1/scanner-sync');

  SyncConfig get syncConfig => SyncConfig(endpoint: syncEndpoint, token: token);

  String toJson() => jsonEncode({'server': serverBase.toString(), 'scanner_id': scannerId, 'name': name, 'gate': gate, 'token': token});

  /// Null if [text] is not a saved identity (damaged, or from some other version).
  static ScannerIdentity? tryParse(String? text) {
    if (text == null) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, Object?>) return null;
      final server = j['server'] is String ? Uri.tryParse(j['server'] as String) : null;
      final id = j['scanner_id'], name = j['name'], gate = j['gate'], token = j['token'];
      if (server == null || server.host.isEmpty || id is! String || name is! String || gate is! String || token is! String || token.isEmpty) return null;
      return ScannerIdentity(serverBase: server, scannerId: id, name: name, gate: gate, token: token);
    } on FormatException {
      return null;
    }
  }
}

/// Where the identity is kept between launches.
abstract interface class IdentityStore {
  Future<ScannerIdentity?> load();
  Future<void> save(ScannerIdentity identity);
  Future<void> clear();
}

/// Android's encrypted preferences, with the key in the Keystore. The token never goes to plain storage.
class SecureIdentityStore implements IdentityStore {
  SecureIdentityStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'dcid.scanner_identity.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<ScannerIdentity?> load() async => ScannerIdentity.tryParse(await _storage.read(key: _key));

  @override
  Future<void> save(ScannerIdentity identity) => _storage.write(key: _key, value: identity.toJson());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// For tests and previews.
class MemoryIdentityStore implements IdentityStore {
  MemoryIdentityStore([this._identity]);

  ScannerIdentity? _identity;

  @override
  Future<ScannerIdentity?> load() async => _identity;

  @override
  Future<void> save(ScannerIdentity identity) async => _identity = identity;

  @override
  Future<void> clear() async => _identity = null;
}
