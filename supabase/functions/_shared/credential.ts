// Digital Campus ID credential format v1. The normative description is docs/credential-spec.md;
// spec/test-vectors/v1.json is the executable contract. The Dart package credential_core must
// agree with this file on every vector.

import { p256 } from '@noble/curves/p256';
import { sha256 } from '@noble/hashes/sha256';
import * as cbor from './cbor.ts';

export const FORMAT_VERSION = 1;
export const DEFAULT_MAX_AGE_S = 45;
export const DEFAULT_MAX_FUTURE_S = 10;
const MAX_QR_CHARS = 1024;

const ascii = (s: string) => new TextEncoder().encode(s);
export const CTX_CRED = ascii('DCID1-CRED\0');
export const CTX_SCAN = ascii('DCID1-SCAN\0');
export const CTX_REVO = ascii('DCID1-REVO\0');

export const PassType = { Student: 0, Fresher: 1, Visitor: 2 } as const;

export interface Credential {
  v: number;
  kv: number;
  sid: number;
  roll: string;
  name: string;
  branch: string;
  year: number;
  pass: number;
  photo: Uint8Array; // first 16 bytes of SHA-256 of the approved photo file
  dpk: Uint8Array; // device public key, compressed SEC1 (33 bytes)
  iat: number;
  exp: number;
}

export type ScanFailure =
  | 'MALFORMED'
  | 'UNSUPPORTED_VERSION'
  | 'UNKNOWN_KEY_VERSION'
  | 'BAD_COLLEGE_SIG'
  | 'BAD_DEVICE_SIG'
  | 'CLOCK_MISMATCH'
  | 'EXPIRED'
  | 'REVOKED';

export type ScanOutcome = { ok: true; credential: Credential; ts: number } | { ok: false; code: ScanFailure };

export type RevocationFailure = 'MALFORMED' | 'UNSUPPORTED_VERSION' | 'UNKNOWN_KEY_VERSION' | 'BAD_SIGNATURE';

export interface RevocationList {
  kv: number;
  seq: number;
  iat: number;
  entries: Array<[number, number]>; // [student id, revoked_at]
}

export type RevocationOutcome = { ok: true; list: RevocationList } | { ok: false; code: RevocationFailure };

/** Signs `message` (the context-prefixed bytes) and returns a raw 64-byte r||s signature. */
export type SignFn = (message: Uint8Array) => Promise<Uint8Array>;

class Failure<C extends string> extends Error {
  code: C;
  constructor(code: C) {
    super(code);
    this.code = code;
  }
}

// ---------------------------------------------------------------- bytes and base64url

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};

const u64be = (n: number): Uint8Array => {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, BigInt(n));
  return b;
};

export function toBase64Url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

export function fromBase64Url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const padded = text.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - (text.length % 4)) % 4);
  const bin = atob(padded);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

// ---------------------------------------------------------------- ECDSA P-256 (raw r||s)

export function verifyEcdsa(publicKey: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean {
  try {
    // lowS: false on purpose. Android Keystore does not normalise s.
    return p256.verify(p256.Signature.fromCompact(signature), sha256(message), publicKey, { lowS: false });
  } catch {
    return false;
  }
}

/** Deterministic (RFC 6979) software signer. Used by tests, tools and the prototype's env-key signer. */
export function signEcdsa(privateKey: Uint8Array, message: Uint8Array): Uint8Array {
  return p256.sign(sha256(message), privateKey, { lowS: false }).toCompactRawBytes();
}

export const publicKeyOf = (privateKey: Uint8Array): Uint8Array => p256.getPublicKey(privateKey, true);

/** Android Keystore and cloud KMS return DER; the wire format is raw r||s. */
export const ecdsaDerToRaw = (der: Uint8Array): Uint8Array => p256.Signature.fromDER(der).toCompactRawBytes();

// ---------------------------------------------------------------- credential

export function encodeCredential(c: Credential): Uint8Array {
  return cbor.map([
    [0, cbor.uint(c.v)],
    [1, cbor.uint(c.kv)],
    [2, cbor.uint(c.sid)],
    [3, cbor.tstr(c.roll)],
    [4, cbor.tstr(c.name)],
    [5, cbor.tstr(c.branch)],
    [6, cbor.uint(c.year)],
    [7, cbor.uint(c.pass)],
    [8, cbor.bstr(c.photo)],
    [9, cbor.bstr(c.dpk)],
    [10, cbor.uint(c.iat)],
    [11, cbor.uint(c.exp)],
  ]);
}

const byteLength = (s: string) => new TextEncoder().encode(s).length;

function parseCredential(bytes: Uint8Array): Credential {
  let top: cbor.CborValue;
  try {
    top = cbor.decode(bytes);
  } catch {
    throw new Failure<ScanFailure>('MALFORMED');
  }
  if (!(top instanceof Map)) throw new Failure<ScanFailure>('MALFORMED');

  const version = top.get(0);
  if (typeof version !== 'number') throw new Failure<ScanFailure>('MALFORMED');
  if (version !== FORMAT_VERSION) throw new Failure<ScanFailure>('UNSUPPORTED_VERSION');

  const num = (k: number): number => {
    const x = top.get(k);
    if (typeof x !== 'number') throw new Failure<ScanFailure>('MALFORMED');
    return x;
  };
  const text = (k: number, min: number, max: number): string => {
    const x = top.get(k);
    if (typeof x !== 'string') throw new Failure<ScanFailure>('MALFORMED');
    const n = byteLength(x);
    if (n < min || n > max) throw new Failure<ScanFailure>('MALFORMED');
    return x;
  };
  const bytesOf = (k: number, len: number): Uint8Array => {
    const x = top.get(k);
    if (!(x instanceof Uint8Array) || x.length !== len) throw new Failure<ScanFailure>('MALFORMED');
    return x;
  };

  const c: Credential = {
    v: version,
    kv: num(1),
    sid: num(2),
    roll: text(3, 1, 16),
    name: text(4, 1, 64),
    branch: text(5, 1, 12),
    year: num(6),
    pass: num(7),
    photo: bytesOf(8, 16),
    dpk: bytesOf(9, 33),
    iat: num(10),
    exp: num(11),
  };
  const valid =
    c.sid >= 1 &&
    c.year >= 1 &&
    c.year <= 6 &&
    c.pass <= PassType.Visitor &&
    (c.dpk[0] === 0x02 || c.dpk[0] === 0x03) &&
    c.exp > c.iat;
  if (!valid) throw new Failure<ScanFailure>('MALFORMED');
  return c;
}

export function decodeCredential(bytes: Uint8Array): Credential {
  try {
    return parseCredential(bytes);
  } catch (e) {
    if (e instanceof Failure) throw new Error(`credential rejected: ${e.code}`);
    throw e;
  }
}

/** The bytes the college key signs. */
export const collegeSigningInput = (credentialBytes: Uint8Array) => concat(CTX_CRED, credentialBytes);
/** The bytes the device key signs for each QR refresh. */
export const deviceSigningInput = (ts: number, credentialBytes: Uint8Array) => concat(CTX_SCAN, u64be(ts), credentialBytes);

// ---------------------------------------------------------------- issuing

export interface IssuedCredential {
  credentialBytes: Uint8Array;
  collegeSig: Uint8Array;
  /** `DK1.` + base64url(CBOR [credential, college_sig]); what the phone downloads and stores. */
  signedText: string;
}

export async function issueCredential(c: Credential, sign: SignFn): Promise<IssuedCredential> {
  const credentialBytes = encodeCredential(c);
  const collegeSig = await sign(collegeSigningInput(credentialBytes));
  if (collegeSig.length !== 64) throw new Error('signer must return raw 64-byte r||s (convert DER with ecdsaDerToRaw)');
  const signedText = 'DK1.' + toBase64Url(cbor.array([cbor.bstr(credentialBytes), cbor.bstr(collegeSig)]));
  return { credentialBytes, collegeSig, signedText };
}

export function parseSignedCredential(text: string): { credentialBytes: Uint8Array; collegeSig: Uint8Array } | null {
  if (!text.startsWith('DK1.')) return null;
  const body = fromBase64Url(text.slice(4));
  if (!body) return null;
  try {
    const arr = cbor.decode(body);
    if (!Array.isArray(arr) || arr.length !== 2) return null;
    const [cred, sig] = arr;
    if (!(cred instanceof Uint8Array) || !(sig instanceof Uint8Array) || sig.length !== 64) return null;
    return { credentialBytes: cred, collegeSig: sig };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- QR

export function encodeQr(credentialBytes: Uint8Array, collegeSig: Uint8Array, ts: number, deviceSig: Uint8Array): string {
  const env = cbor.array([cbor.bstr(credentialBytes), cbor.bstr(collegeSig), cbor.uint(ts), cbor.bstr(deviceSig)]);
  return 'DC1.' + toBase64Url(env);
}

/** Software stand-in for the phone: signs the timestamp with a local key. Tests and tools only. */
export function buildScanQr(issued: Pick<IssuedCredential, 'credentialBytes' | 'collegeSig'>, ts: number, devicePrivateKey: Uint8Array): string {
  const deviceSig = signEcdsa(devicePrivateKey, deviceSigningInput(ts, issued.credentialBytes));
  return encodeQr(issued.credentialBytes, issued.collegeSig, ts, deviceSig);
}

interface Envelope {
  credentialBytes: Uint8Array;
  collegeSig: Uint8Array;
  ts: number;
  deviceSig: Uint8Array;
}

function parseEnvelope(text: string): Envelope {
  if (text.length > MAX_QR_CHARS) throw new Failure<ScanFailure>('MALFORMED');
  const m = /^DC([0-9]{1,3})\./.exec(text);
  if (!m) throw new Failure<ScanFailure>('MALFORMED');
  if (Number(m[1]) !== FORMAT_VERSION) throw new Failure<ScanFailure>('UNSUPPORTED_VERSION');

  const body = fromBase64Url(text.slice(m[0].length));
  if (!body) throw new Failure<ScanFailure>('MALFORMED');
  let arr: cbor.CborValue;
  try {
    arr = cbor.decode(body);
  } catch {
    throw new Failure<ScanFailure>('MALFORMED');
  }
  if (!Array.isArray(arr) || arr.length !== 4) throw new Failure<ScanFailure>('MALFORMED');
  const [credentialBytes, collegeSig, ts, deviceSig] = arr;
  if (
    !(credentialBytes instanceof Uint8Array) ||
    !(collegeSig instanceof Uint8Array) ||
    collegeSig.length !== 64 ||
    typeof ts !== 'number' ||
    !(deviceSig instanceof Uint8Array) ||
    deviceSig.length !== 64
  ) {
    throw new Failure<ScanFailure>('MALFORMED');
  }
  return { credentialBytes, collegeSig, ts, deviceSig };
}

export interface VerifyOptions {
  /** Corrected scanner clock, unix seconds. */
  now: number;
  /** College public keys by key version (compressed SEC1). */
  keys: ReadonlyMap<number, Uint8Array>;
  /** Parsed revocation entries from a list that has already passed verifyRevocationList. */
  revoked?: ReadonlyArray<readonly [number, number]>;
  maxAgeS?: number;
  maxFutureS?: number;
}

export function verifyScan(text: string, o: VerifyOptions): ScanOutcome {
  try {
    const env = parseEnvelope(text);
    const credential = parseCredential(env.credentialBytes);

    const collegeKey = o.keys.get(credential.kv);
    if (!collegeKey) throw new Failure<ScanFailure>('UNKNOWN_KEY_VERSION');
    if (!verifyEcdsa(collegeKey, collegeSigningInput(env.credentialBytes), env.collegeSig)) {
      throw new Failure<ScanFailure>('BAD_COLLEGE_SIG');
    }
    if (!verifyEcdsa(credential.dpk, deviceSigningInput(env.ts, env.credentialBytes), env.deviceSig)) {
      throw new Failure<ScanFailure>('BAD_DEVICE_SIG');
    }

    const age = o.now - env.ts;
    if (age > (o.maxAgeS ?? DEFAULT_MAX_AGE_S) || -age > (o.maxFutureS ?? DEFAULT_MAX_FUTURE_S)) {
      throw new Failure<ScanFailure>('CLOCK_MISMATCH');
    }
    if (o.now >= credential.exp) throw new Failure<ScanFailure>('EXPIRED');
    if (o.revoked?.some(([sid, at]) => sid === credential.sid && credential.iat <= at)) {
      throw new Failure<ScanFailure>('REVOKED');
    }
    return { ok: true, credential, ts: env.ts };
  } catch (e) {
    if (e instanceof Failure) return { ok: false, code: e.code as ScanFailure };
    throw e;
  }
}

// ---------------------------------------------------------------- revocation list

export async function encodeRevocationList(list: RevocationList, sign: SignFn): Promise<string> {
  const payload = cbor.map([
    [0, cbor.uint(FORMAT_VERSION)],
    [1, cbor.uint(list.kv)],
    [2, cbor.uint(list.seq)],
    [3, cbor.uint(list.iat)],
    [4, cbor.array(list.entries.map(([sid, at]) => cbor.array([cbor.uint(sid), cbor.uint(at)])))],
  ]);
  const sig = await sign(concat(CTX_REVO, payload));
  if (sig.length !== 64) throw new Error('signer must return raw 64-byte r||s');
  return 'DR1.' + toBase64Url(cbor.array([cbor.bstr(payload), cbor.bstr(sig)]));
}

export function verifyRevocationList(text: string, keys: ReadonlyMap<number, Uint8Array>): RevocationOutcome {
  const fail = (code: RevocationFailure): RevocationOutcome => ({ ok: false, code });
  const m = /^DR([0-9]{1,3})\./.exec(text);
  if (!m) return fail('MALFORMED');
  if (Number(m[1]) !== FORMAT_VERSION) return fail('UNSUPPORTED_VERSION');
  const body = fromBase64Url(text.slice(m[0].length));
  if (!body) return fail('MALFORMED');

  let payloadBytes: Uint8Array;
  let sig: Uint8Array;
  let payload: cbor.CborValue;
  try {
    const arr = cbor.decode(body);
    if (!Array.isArray(arr) || arr.length !== 2) return fail('MALFORMED');
    const [p, s] = arr;
    if (!(p instanceof Uint8Array) || !(s instanceof Uint8Array) || s.length !== 64) return fail('MALFORMED');
    payloadBytes = p;
    sig = s;
    payload = cbor.decode(p);
  } catch {
    return fail('MALFORMED');
  }
  if (!(payload instanceof Map)) return fail('MALFORMED');
  const [v, kv, seq, iat, rawEntries] = [0, 1, 2, 3, 4].map((k) => payload.get(k));
  if (v !== FORMAT_VERSION) return fail('UNSUPPORTED_VERSION');
  if (typeof kv !== 'number' || typeof seq !== 'number' || typeof iat !== 'number' || !Array.isArray(rawEntries)) {
    return fail('MALFORMED');
  }
  const entries: Array<[number, number]> = [];
  for (const e of rawEntries) {
    if (!Array.isArray(e) || e.length !== 2 || typeof e[0] !== 'number' || typeof e[1] !== 'number') return fail('MALFORMED');
    entries.push([e[0], e[1]]);
  }

  const key = keys.get(kv);
  if (!key) return fail('UNKNOWN_KEY_VERSION');
  if (!verifyEcdsa(key, concat(CTX_REVO, payloadBytes), sig)) return fail('BAD_SIGNATURE');
  return { ok: true, list: { kv, seq, iat, entries } };
}

// ---------------------------------------------------------------- key set

export interface KeySetDocument {
  v: number;
  current: number;
  keys: Array<{ kv: number; alg: string; pub: string }>;
}

export function parseKeySet(doc: KeySetDocument): Map<number, Uint8Array> {
  if (doc.v !== 1) throw new Error('unsupported key set version');
  const out = new Map<number, Uint8Array>();
  for (const k of doc.keys) {
    const pub = fromBase64Url(k.pub);
    if (k.alg !== 'ES256' || !pub || pub.length !== 33) throw new Error(`bad key entry kv=${k.kv}`);
    out.set(k.kv, pub);
  }
  if (!out.has(doc.current)) throw new Error('current key missing from key set');
  return out;
}
