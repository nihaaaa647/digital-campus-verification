import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';

const String keystoreChannelName = 'app.dcid.student_app/keystore';

/// Where the device key lives, best first. `software` means the phone has no secure hardware, which
/// the spec allows ("where the phone has one") but the admin may want to know about.
enum KeySecurity {
  strongbox,
  tee,
  software,
  unknown;

  static KeySecurity parse(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return KeySecurity.unknown;
  }
}

/// The phone's device key as the rest of the app sees it.
class DeviceKey {
  const DeviceKey(this.publicKey, this.security);

  /// Compressed SEC1 public key, 33 bytes: the `dpk` field of the credential.
  final Uint8List publicKey;
  final KeySecurity security;
}

class KeystoreException implements Exception {
  const KeystoreException(this.code, this.message);

  /// `no_key`, `keystore_error`, or `bad_response` when the platform answered with something unusable.
  final String code;
  final String message;

  @override
  String toString() => 'KeystoreException($code): $message';
}

/// Signs with the Android Keystore through `KeystoreChannel.kt`. The Keystore returns DER and an X.509
/// public key; this class converts them to the raw `r || s` and compressed key the credential format
/// uses, so nothing else in the app deals with either.
class KeystoreSigner implements DeviceSigner {
  KeystoreSigner({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(keystoreChannelName);

  final MethodChannel _channel;

  /// The existing device key, or null if this phone has none.
  Future<DeviceKey?> existingKey() => _key(create: false);

  /// The device key, generating it on first use. Call this when enrolling, before asking the server for
  /// a credential, because the credential must carry this key's public half.
  Future<DeviceKey> getOrCreateKey() async => (await _key(create: true))!;

  Future<DeviceKey?> _key({required bool create}) async {
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<Object?, Object?>('key', {'create': create});
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'platform error');
    }
    if (reply == null) return null;
    final spki = reply['publicKey'];
    if (spki is! Uint8List) throw const KeystoreException('bad_response', 'no public key in reply');
    try {
      return DeviceKey(compressedPublicKeyFromSpki(spki), KeySecurity.parse(reply['security']));
    } on ArgumentError catch (e) {
      throw KeystoreException('bad_response', 'unexpected public key: ${e.message}');
    }
  }

  /// Signs SHA-256(message) and returns the raw 64-byte `r || s` that [buildScanQr] requires.
  @override
  Future<Uint8List> signRaw(Uint8List message) async {
    final Uint8List? der;
    try {
      der = await _channel.invokeMethod<Uint8List>('sign', {'message': message});
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'platform error');
    }
    if (der == null) throw const KeystoreException('bad_response', 'no signature in reply');
    try {
      return ecdsaDerToRaw(der);
    } on FormatException catch (e) {
      throw KeystoreException('bad_response', 'unexpected signature: ${e.message}');
    }
  }

  /// Removes the device key. Every credential issued to it stops working, so only sign-out and
  /// device-change flows should call this.
  Future<void> deleteKey() async {
    try {
      await _channel.invokeMethod<void>('deleteKey');
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'platform error');
    }
  }
}
