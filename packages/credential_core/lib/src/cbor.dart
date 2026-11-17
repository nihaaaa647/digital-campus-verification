import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

/// Minimal CBOR (RFC 8949) subset used by the credential format: unsigned integers, byte strings,
/// text strings, arrays and maps with unsigned-integer keys. Encoding is deterministic. Decoding is
/// strict about structure but does not insist on shortest-form integers, because signatures cover
/// the exact bytes received.
class CborException implements Exception {
  CborException(this.message);
  final String message;

  @override
  String toString() => 'CborException: $message';
}

const int _maxSafeInt = 9007199254740991; // 2^53 - 1
const int _maxDepth = 8;

Uint8List _head(int major, int n) {
  if (n < 0 || n > _maxSafeInt) throw CborException('integer out of range');
  if (n < 24) return Uint8List.fromList([(major << 5) | n]);
  if (n < 0x100) return Uint8List.fromList([(major << 5) | 24, n]);
  if (n < 0x10000) return Uint8List.fromList([(major << 5) | 25, n >> 8, n & 0xff]);
  if (n < 0x100000000) {
    final b = Uint8List(5);
    b[0] = (major << 5) | 26;
    ByteData.sublistView(b).setUint32(1, n);
    return b;
  }
  final b = Uint8List(9);
  b[0] = (major << 5) | 27;
  ByteData.sublistView(b)
    ..setUint32(1, n ~/ 0x100000000)
    ..setUint32(5, n % 0x100000000);
  return b;
}

Uint8List cborUint(int n) => _head(0, n);

Uint8List cborBytes(List<int> b) => concatBytes([_head(2, b.length), b]);

/// The caller is responsible for Unicode NFC. Dart has no normaliser; issuing happens on the server.
Uint8List cborText(String s) {
  final u = utf8.encode(s);
  return concatBytes([_head(3, u.length), u]);
}

Uint8List cborArray(List<Uint8List> items) => concatBytes([_head(4, items.length), ...items]);

/// Map keys are written in ascending order.
Uint8List cborMap(Map<int, Uint8List> entries) {
  final keys = entries.keys.toList()..sort();
  return concatBytes([_head(5, keys.length), for (final k in keys) ...[cborUint(k), entries[k]!]]);
}

/// Decodes one CBOR item. Result types: `int`, `Uint8List`, `String`, `List<Object>`, `Map<int, Object>`.
/// Throws [CborException] on anything outside the subset or on trailing bytes.
Object decodeCbor(Uint8List data) {
  final r = _Reader(data);
  final value = r.readItem(0);
  if (r.pos != data.length) throw CborException('trailing bytes');
  return value;
}

class _Reader {
  _Reader(this.buf);

  final Uint8List buf;
  int pos = 0;

  void need(int n) {
    if (n > buf.length - pos) throw CborException('unexpected end of data');
  }

  int readArgument(int additional) {
    if (additional < 24) return additional;
    final size = switch (additional) { 24 => 1, 25 => 2, 26 => 4, 27 => 8, _ => 0 };
    if (size == 0) throw CborException('indefinite length or reserved encoding');
    need(size);
    // Eight-byte values above 2^53 - 1 are rejected so that no platform has to cope with them.
    if (size == 8 && (buf[pos] != 0 || buf[pos + 1] >= 0x20)) throw CborException('integer exceeds 2^53 - 1');
    var n = 0;
    for (var i = 0; i < size; i++) {
      n = n * 256 + buf[pos + i];
    }
    pos += size;
    return n;
  }

  Object readItem(int depth) {
    if (depth > _maxDepth) throw CborException('nesting too deep');
    need(1);
    final initial = buf[pos++];
    final major = initial >> 5;
    final length = readArgument(initial & 31);
    switch (major) {
      case 0:
        return length;
      case 2:
        need(length);
        final out = Uint8List.fromList(buf.sublist(pos, pos + length));
        pos += length;
        return out;
      case 3:
        need(length);
        final text = buf.sublist(pos, pos + length);
        pos += length;
        try {
          return utf8.decode(text);
        } on FormatException {
          throw CborException('invalid UTF-8');
        }
      case 4:
        if (length > buf.length - pos) throw CborException('array longer than data');
        return <Object>[for (var i = 0; i < length; i++) readItem(depth + 1)];
      case 5:
        if (length * 2 > buf.length - pos) throw CborException('map longer than data');
        final out = <int, Object>{};
        for (var i = 0; i < length; i++) {
          final key = readItem(depth + 1);
          if (key is! int) throw CborException('map keys must be unsigned integers');
          if (out.containsKey(key)) throw CborException('duplicate map key');
          out[key] = readItem(depth + 1);
        }
        return out;
      default:
        throw CborException('unsupported major type');
    }
  }
}
