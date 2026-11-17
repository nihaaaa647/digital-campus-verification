import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the phone keeps between launches: the college-signed credential and how far the phone's clock
/// was from the server's when it was issued.
class StoredPass {
  const StoredPass({required this.signedCredential, required this.serverOffsetS});

  /// The `DK1.` text returned by `issue-credential` (docs/credential-spec.md section 5).
  final String signedCredential;

  /// Server time minus phone time, in seconds, recorded at the last online contact. Added to the
  /// phone's clock when signing `ts` (spec section 6).
  final int serverOffsetS;
}

abstract interface class PassStore {
  Future<StoredPass?> load();
  Future<void> save(StoredPass pass);
  Future<void> clear();
}

/// Keeps the credential in Android's encrypted preferences. It holds the student's name and roll
/// number, so it is kept off plain storage; `allowBackup` is off in the manifest so a restored backup
/// can never carry it to another phone.
class SecurePassStore implements PassStore {
  SecurePassStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _credentialKey = 'dcid.credential.v1';
  static const _offsetKey = 'dcid.server_offset_s.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredPass?> load() async {
    final text = await _storage.read(key: _credentialKey);
    if (text == null) return null;
    final offset = int.tryParse(await _storage.read(key: _offsetKey) ?? '') ?? 0;
    return StoredPass(signedCredential: text, serverOffsetS: offset);
  }

  @override
  Future<void> save(StoredPass pass) async {
    await _storage.write(key: _credentialKey, value: pass.signedCredential);
    await _storage.write(key: _offsetKey, value: '${pass.serverOffsetS}');
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _credentialKey);
    await _storage.delete(key: _offsetKey);
  }
}

/// For tests and previews.
class MemoryPassStore implements PassStore {
  MemoryPassStore([this._pass]);

  StoredPass? _pass;

  @override
  Future<StoredPass?> load() async => _pass;

  @override
  Future<void> save(StoredPass pass) async => _pass = pass;

  @override
  Future<void> clear() async => _pass = null;
}
