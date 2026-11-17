import 'dart:convert';
import 'dart:io';

import 'package:credential_core/credential_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanner_app/src/key_set.dart';

import 'support/vectors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vec = Vectors.load();

  test('the bundled dev key set is exactly the key set in the test vectors', () {
    final bundled = jsonDecode(File('assets/keys/dev-keyset.json').readAsStringSync());
    expect(bundled, vec.json['keyset_json'], reason: 'regenerate assets/keys/dev-keyset.json from spec/test-vectors/v1.json');
  });

  test('loading it from the asset bundle gives the current and the previous college key', () async {
    final keys = await const AssetKeySet(devKeySetAsset).load();

    expect(keys.keys.toSet(), {1, 2});
    for (final kv in [1, 2]) {
      expect(bytesToHex(keys[kv]!), bytesToHex(vec.collegePublic[kv]!));
    }
  });

  test('a key set that is not a JSON object is refused', () async {
    final bundle = _OneFileBundle('[1, 2, 3]');
    await expectLater(AssetKeySet('x.json', bundle: bundle).load(), throwsFormatException);
  });

  test('a key set with a wrong version or a bad key is refused', () async {
    for (final doc in [
      '{"v": 2, "current": 1, "keys": []}',
      '{"v": 1, "current": 1, "keys": [{"kv": 1, "alg": "ES256", "pub": "AAAA"}]}',
      '{"v": 1, "current": 9, "keys": [{"kv": 1, "alg": "ES256", "pub": "Ah4-507MElKR9T9-Uj_W86YfS0e7KB0fI4OGrw9-ZXf9"}]}',
    ]) {
      await expectLater(AssetKeySet('x.json', bundle: _OneFileBundle(doc)).load(), throwsFormatException, reason: doc);
    }
  });
}

class _OneFileBundle extends CachingAssetBundle {
  _OneFileBundle(this.text);

  final String text;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
}
