import 'dart:convert';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';

/// The development key set: the PUBLIC test college keys from spec/test-vectors/v1.json. A scanner that
/// trusts these accepts every demo pass and every copy of the test vectors, so it is loaded only when
/// the app is started with dev keys (see main.dart).
const String devKeySetAsset = 'assets/keys/dev-keyset.json';

/// Where the scanner gets the college public keys it trusts (docs/credential-spec.md section 8).
abstract interface class KeySetSource {
  /// Key version -> compressed public key. Throws [FormatException] if the document is malformed.
  Future<Map<int, Uint8List>> load();
}

class AssetKeySet implements KeySetSource {
  const AssetKeySet(this.assetPath, {AssetBundle? bundle}) : _bundle = bundle;

  final String assetPath;
  final AssetBundle? _bundle;

  @override
  Future<Map<int, Uint8List>> load() async {
    final text = await (_bundle ?? rootBundle).loadString(assetPath);
    final doc = jsonDecode(text);
    if (doc is! Map<String, Object?>) throw const FormatException('key set is not a JSON object');
    return parseKeySet(doc);
  }
}
