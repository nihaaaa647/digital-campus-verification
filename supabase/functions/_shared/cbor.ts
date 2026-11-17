// Minimal CBOR (RFC 8949) subset used by the credential format: unsigned integers,
// byte strings, text strings, arrays and maps with unsigned-integer keys.
// Encoding is deterministic (definite lengths, shortest integers, ascending map keys).
// Decoding is strict about structure but does not insist on shortest-form integers,
// because signatures cover the exact bytes received.

export class CborError extends Error {}

export type CborValue = number | Uint8Array | string | CborValue[] | Map<number, CborValue>;

const MAX_DEPTH = 8;
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function head(major: number, n: number): Uint8Array {
  if (!Number.isSafeInteger(n) || n < 0) throw new CborError('integer out of range');
  if (n < 24) return Uint8Array.of((major << 5) | n);
  if (n < 0x100) return Uint8Array.of((major << 5) | 24, n);
  if (n < 0x10000) return Uint8Array.of((major << 5) | 25, n >> 8, n & 0xff);
  if (n < 0x100000000) {
    const b = new Uint8Array(5);
    b[0] = (major << 5) | 26;
    new DataView(b.buffer).setUint32(1, n);
    return b;
  }
  const b = new Uint8Array(9);
  b[0] = (major << 5) | 27;
  new DataView(b.buffer).setBigUint64(1, BigInt(n));
  return b;
}

export const uint = (n: number): Uint8Array => head(0, n);
export const bstr = (b: Uint8Array): Uint8Array => concat([head(2, b.length), b]);
export const tstr = (s: string): Uint8Array => {
  const u = utf8Encoder.encode(s.normalize('NFC'));
  return concat([head(3, u.length), u]);
};
export const array = (items: Uint8Array[]): Uint8Array => concat([head(4, items.length), ...items]);
export const map = (entries: Array<[number, Uint8Array]>): Uint8Array => {
  const sorted = [...entries].sort((a, b) => a[0] - b[0]);
  return concat([head(5, sorted.length), ...sorted.flatMap(([k, v]) => [uint(k), v])]);
};

interface Reader {
  buf: Uint8Array;
  pos: number;
}

function need(r: Reader, n: number): void {
  if (n > r.buf.length - r.pos) throw new CborError('unexpected end of data');
}

function readArgument(r: Reader, additional: number): number {
  if (additional < 24) return additional;
  const size = additional === 24 ? 1 : additional === 25 ? 2 : additional === 26 ? 4 : additional === 27 ? 8 : 0;
  if (size === 0) throw new CborError('indefinite length or reserved encoding');
  need(r, size);
  if (size === 8) {
    const big = new DataView(r.buf.buffer, r.buf.byteOffset + r.pos, 8).getBigUint64(0);
    r.pos += 8;
    if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new CborError('integer exceeds 2^53 - 1');
    return Number(big);
  }
  let n = 0;
  for (let i = 0; i < size; i++) n = n * 256 + r.buf[r.pos + i];
  r.pos += size;
  return n;
}

function readItem(r: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) throw new CborError('nesting too deep');
  need(r, 1);
  const initial = r.buf[r.pos++];
  const major = initial >> 5;
  const length = readArgument(r, initial & 31);
  switch (major) {
    case 0:
      return length;
    case 2: {
      need(r, length);
      const out = r.buf.slice(r.pos, r.pos + length);
      r.pos += length;
      return out;
    }
    case 3: {
      need(r, length);
      const text = r.buf.subarray(r.pos, r.pos + length);
      r.pos += length;
      try {
        return utf8Decoder.decode(text);
      } catch {
        throw new CborError('invalid UTF-8');
      }
    }
    case 4: {
      if (length > r.buf.length - r.pos) throw new CborError('array longer than data');
      const out: CborValue[] = [];
      for (let i = 0; i < length; i++) out.push(readItem(r, depth + 1));
      return out;
    }
    case 5: {
      if (length * 2 > r.buf.length - r.pos) throw new CborError('map longer than data');
      const out = new Map<number, CborValue>();
      for (let i = 0; i < length; i++) {
        const key = readItem(r, depth + 1);
        if (typeof key !== 'number') throw new CborError('map keys must be unsigned integers');
        if (out.has(key)) throw new CborError('duplicate map key');
        out.set(key, readItem(r, depth + 1));
      }
      return out;
    }
    default:
      throw new CborError('unsupported major type');
  }
}

export function decode(buf: Uint8Array): CborValue {
  const r: Reader = { buf, pos: 0 };
  const value = readItem(r, 0);
  if (r.pos !== buf.length) throw new CborError('trailing bytes');
  return value;
}
