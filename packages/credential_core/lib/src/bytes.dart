import 'dart:convert';
import 'dart:typed_data';

final _hexDigits = RegExp(r'^([0-9a-fA-F]{2})*$');
final _base64UrlAlphabet = RegExp(r'^[A-Za-z0-9_-]*$');

String bytesToHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexToBytes(String hex) {
  if (!_hexDigits.hasMatch(hex)) throw FormatException('not a hex string', hex);
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Base64url without padding (RFC 4648 section 5).
String toBase64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Strict decode: only the base64url alphabet, no padding, no impossible lengths. Returns null on bad input.
Uint8List? fromBase64Url(String text) {
  if (!_base64UrlAlphabet.hasMatch(text) || text.length % 4 == 1) return null;
  final padded = text + '=' * ((4 - text.length % 4) % 4);
  try {
    return base64Url.decode(padded);
  } on FormatException {
    return null;
  }
}

Uint8List concatBytes(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

/// Big-endian unsigned 64-bit encoding.
Uint8List u64be(int n) {
  final b = Uint8List(8);
  final view = ByteData.sublistView(b);
  view.setUint32(0, n ~/ 0x100000000);
  view.setUint32(4, n % 0x100000000);
  return b;
}
