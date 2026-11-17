// Generates spec/test-vectors/v1.json for the Digital Campus ID credential format.
//
//   node tools/gen-vectors/gen.mjs
//
// Zero dependencies (node:crypto only) and fully deterministic: keys are derived from
// fixed seeds and signatures use RFC 6979, so re-running produces a byte-identical file.
// The keys in the output are TEST KEYS. Never use them for anything real.
//
// This generator is deliberately independent of the implementations under test
// (credential_core in Dart, _shared/credential.ts in TypeScript) so that a bug in
// one of those cannot hide behind a matching bug here.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------- primitives

const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n; // P-256 group order
const HALF_N = N >> 1n;

const sha256 = (b) => crypto.createHash('sha256').update(b).digest();
const hmac = (key, ...parts) => {
  const h = crypto.createHmac('sha256', key);
  for (const p of parts) h.update(Buffer.from(p));
  return h.digest();
};
const cat = (...parts) => Buffer.concat(parts.map((p) => Buffer.from(p)));
const hex = (b) => Buffer.from(b).toString('hex');
const b64u = (b) => Buffer.from(b).toString('base64url');
const bigOf = (b) => BigInt('0x' + (hex(b) || '0'));
const bytesOf = (n, len = 32) => Buffer.from(n.toString(16).padStart(len * 2, '0'), 'hex');
const u64be = (n) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
};

// ---------------------------------------------------------------- CBOR subset
// Definite lengths, shortest-form integers, map keys ascending. Nothing else is needed.

function head(major, value) {
  const n = BigInt(value);
  if (n < 24n) return Buffer.from([(major << 5) | Number(n)]);
  if (n < 256n) return Buffer.from([(major << 5) | 24, Number(n)]);
  if (n < 65536n) {
    const b = Buffer.alloc(3);
    b[0] = (major << 5) | 25;
    b.writeUInt16BE(Number(n), 1);
    return b;
  }
  if (n < 4294967296n) {
    const b = Buffer.alloc(5);
    b[0] = (major << 5) | 26;
    b.writeUInt32BE(Number(n), 1);
    return b;
  }
  const b = Buffer.alloc(9);
  b[0] = (major << 5) | 27;
  b.writeBigUInt64BE(n, 1);
  return b;
}
const cUint = (n) => head(0, n);
const cBstr = (b) => cat(head(2, b.length), b);
const cTstr = (s) => {
  const u = Buffer.from(s.normalize('NFC'), 'utf8');
  return cat(head(3, u.length), u);
};
const cArr = (items) => cat(head(4, items.length), ...items);
const cMap = (entries) => {
  const sorted = [...entries].sort((a, b) => a[0] - b[0]);
  return cat(head(5, sorted.length), ...sorted.flatMap(([k, v]) => [cUint(k), v]));
};

// ---------------------------------------------------------------- ECDSA P-256 / SHA-256, raw r||s

const ecdhFor = (priv) => {
  const e = crypto.createECDH('prime256v1');
  e.setPrivateKey(priv);
  return e;
};
const publicKey = (priv) => ecdhFor(priv).getPublicKey(null, 'compressed');

function modPow(base, exp, mod) {
  let result = 1n;
  let b = base % mod;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % mod;
    b = (b * b) % mod;
    e >>= 1n;
  }
  return result;
}

// RFC 6979 section 3.2 with HMAC-SHA-256, qlen = hlen = 256.
function signRaw(priv, message) {
  const z = bigOf(sha256(message));
  const d = bigOf(priv);
  const x = bytesOf(d);
  const h1 = bytesOf(z % N);
  let V = Buffer.alloc(32, 0x01);
  let K = Buffer.alloc(32, 0x00);
  K = hmac(K, V, [0x00], x, h1);
  V = hmac(K, V);
  K = hmac(K, V, [0x01], x, h1);
  V = hmac(K, V);
  for (;;) {
    V = hmac(K, V);
    const k = bigOf(V);
    if (k >= 1n && k < N) {
      const R = ecdhFor(bytesOf(k)).getPublicKey(null, 'uncompressed');
      const r = bigOf(R.subarray(1, 33)) % N;
      const s = (modPow(k, N - 2n, N) * ((z + r * d) % N)) % N;
      if (r !== 0n && s !== 0n) return cat(bytesOf(r), bytesOf(s));
    }
    K = hmac(K, V, [0x00]);
    V = hmac(K, V);
  }
}

// Returns the same signature with s forced into the high or low half of the range.
function withS(sig, wantHigh) {
  const s = bigOf(sig.subarray(32));
  if (s > HALF_N === wantHigh) return sig;
  return cat(sig.subarray(0, 32), bytesOf(N - s));
}

const SPKI_P256_PREFIX = Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200', 'hex');
function nodeVerify(compressedPub, message, sig) {
  const uncompressed = crypto.ECDH.convertKey(compressedPub, 'prime256v1', undefined, undefined, 'uncompressed');
  const key = crypto.createPublicKey({ key: cat(SPKI_P256_PREFIX, uncompressed), format: 'der', type: 'spki' });
  return crypto.verify('sha256', message, { key, dsaEncoding: 'ieee-p1363' }, sig);
}

// ---------------------------------------------------------------- format constants (see docs/credential-spec.md)

const CTX_CRED = Buffer.from('DCID1-CRED\0', 'latin1');
const CTX_SCAN = Buffer.from('DCID1-SCAN\0', 'latin1');
const CTX_REVO = Buffer.from('DCID1-REVO\0', 'latin1');
const POLICY = { max_age_s: 45, max_future_s: 10 };

const DAY = 86400;
// 2026-11-03 13:02:14 IST, the timestamp in the PRD's sample export.
const NOW = Math.floor(Date.UTC(2026, 10, 3, 7, 32, 14) / 1000);
const IAT = NOW - 14 * DAY;

// ---------------------------------------------------------------- test keys

const keyFromSeed = (seed) => {
  const d = sha256(Buffer.from(seed, 'utf8'));
  assert(bigOf(d) > 0n && bigOf(d) < N);
  return d;
};
const college = new Map([1, 2, 3].map((kv) => [kv, keyFromSeed(`dcid-test-college-kv${kv}`)]));
const devices = new Map(['dev_a', 'dev_b'].map((name) => [name, keyFromSeed(`dcid-test-device-${name}`)]));

// ---------------------------------------------------------------- builders

const credEntries = (c) => [
  [0, cUint(c.v)],
  [1, cUint(c.kv)],
  [2, cUint(c.sid)],
  [3, cTstr(c.roll)],
  [4, cTstr(c.name)],
  [5, cTstr(c.branch)],
  [6, cUint(c.year)],
  [7, cUint(c.pass)],
  [8, cBstr(c.photo)],
  [9, cBstr(c.dpk)],
  [10, cUint(c.iat)],
  [11, cUint(c.exp)],
];
const encodeCredential = (c) => cMap(credEntries(c));

function checkedSign(priv, message) {
  const sig = signRaw(priv, message);
  assert(nodeVerify(publicKey(priv), message, sig), 'generator produced a signature that node:crypto rejects');
  return sig;
}

const signCredentialBytes = (kv, credBytes) => checkedSign(college.get(kv), cat(CTX_CRED, credBytes));
const signScan = (devicePriv, ts, credBytes) => checkedSign(devicePriv, cat(CTX_SCAN, u64be(ts), credBytes));

const envelope = (credBytes, collegeSig, ts, deviceSig) =>
  cArr([cBstr(credBytes), cBstr(collegeSig), cUint(ts), cBstr(deviceSig)]);
const qrText = (env, version = 1) => `DC${version}.` + b64u(env);

// ---------------------------------------------------------------- credentials

const photoHash = (label) => sha256(Buffer.from(label, 'utf8')).subarray(0, 16);

const credentialDefs = [
  {
    id: 'student_ok',
    description: 'Ordinary student credential signed by the current key (kv 2), device dev_a.',
    fields: { v: 1, kv: 2, sid: 1042, roll: '25071A0001', name: 'Sample Student', branch: 'CSE-AIML', year: 2, pass: 0, photo: photoHash('sample-photo-1042'), device: 'dev_a', iat: IAT, exp: IAT + 180 * DAY },
  },
  {
    id: 'fresher_utf8',
    description: 'Fresher temporary pass (pass 1) with a non-ASCII name, to pin down UTF-8 byte-length handling.',
    fields: { v: 1, kv: 2, sid: 2201, roll: 'ADM26-00317', name: 'Śrāvya Ñandini', branch: 'ECE', year: 1, pass: 1, photo: photoHash('sample-photo-2201'), device: 'dev_b', iat: NOW - 3 * DAY, exp: NOW + 27 * DAY },
  },
  {
    id: 'student_prev_key',
    description: 'Signed by the previous key (kv 1), which scanners still hold.',
    fields: { v: 1, kv: 1, sid: 1043, roll: '25071A0002', name: 'Sample Student', branch: 'ECE', year: 2, pass: 0, photo: photoHash('sample-photo-1043'), device: 'dev_b', iat: IAT, exp: IAT + 180 * DAY },
  },
  {
    id: 'student_unknown_key',
    description: 'Validly signed by kv 3, which is not in the default scanner keyset.',
    fields: { v: 1, kv: 3, sid: 1044, roll: '25071A0003', name: 'Sample Student', branch: 'CSE', year: 2, pass: 0, photo: photoHash('sample-photo-1044'), device: 'dev_a', iat: IAT, exp: IAT + 180 * DAY },
  },
  {
    id: 'student_expired',
    description: 'Expired 20 days before the reference time.',
    fields: { v: 1, kv: 2, sid: 1045, roll: '25071A0004', name: 'Sample Student', branch: 'IT', year: 3, pass: 0, photo: photoHash('sample-photo-1045'), device: 'dev_a', iat: NOW - 200 * DAY, exp: NOW - 20 * DAY },
  },
  {
    id: 'student_exp_edge',
    description: 'exp equals the reference time exactly. exp is exclusive, so it is expired at NOW and valid at NOW - 1.',
    fields: { v: 1, kv: 2, sid: 1047, roll: '25071A0006', name: 'Sample Student', branch: 'CSE', year: 2, pass: 0, photo: photoHash('sample-photo-1047'), device: 'dev_a', iat: NOW - 180 * DAY, exp: NOW },
  },
  {
    id: 'student_future_version',
    description: 'Validly signed credential whose v field is 2.',
    fields: { v: 2, kv: 2, sid: 1046, roll: '25071A0005', name: 'Sample Student', branch: 'CSE', year: 2, pass: 0, photo: photoHash('sample-photo-1046'), device: 'dev_a', iat: IAT, exp: IAT + 180 * DAY },
  },
];

const credentials = new Map();
for (const def of credentialDefs) {
  const f = def.fields;
  const dpk = publicKey(devices.get(f.device));
  const bytes = encodeCredential({ ...f, dpk });
  credentials.set(def.id, { ...def, dpk, bytes, collegeSig: signCredentialBytes(f.kv, bytes) });
}

// A credential with the exp field (key 11) removed, correctly signed: structurally invalid.
const missingFieldCred = (() => {
  const f = credentialDefs[0].fields;
  const dpk = publicKey(devices.get(f.device));
  const entries = credEntries({ ...f, sid: 1048, roll: '25071A0007', dpk }).filter(([k]) => k !== 11);
  const bytes = cMap(entries);
  return { bytes, collegeSig: signCredentialBytes(f.kv, bytes) };
})();

// ---------------------------------------------------------------- scans

function makeScan(credId, { ts, device } = {}) {
  const c = credentials.get(credId);
  const devicePriv = devices.get(device ?? c.fields.device);
  const scanTs = ts ?? NOW - 5;
  return { cred: c, ts: scanTs, env: envelope(c.bytes, c.collegeSig, scanTs, signScan(devicePriv, scanTs, c.bytes)) };
}

const verifyCases = [];
const scanVectors = [];

function addScan(id, description, scan, { version = 1, now = NOW, keyset = [1, 2], revocation = null, expect }) {
  const qr = typeof scan === 'string' ? scan : qrText(scan.env, version);
  verifyCases.push({ id, description, qr, now, keyset, revocation, expect });
  scanVectors.push({ id, qr_chars: qr.length });
}
const ok = (credId, extra = {}) => {
  const f = credentials.get(credId).fields;
  return { result: 'OK', credential: { sid: f.sid, roll: f.roll, name: f.name.normalize('NFC'), branch: f.branch, year: f.year, pass: f.pass, kv: f.kv, exp: f.exp, ...extra } };
};
const fail = (result) => ({ result });

// --- accepted
addScan('ok_basic', 'Fresh scan of an ordinary student pass.', makeScan('student_ok'), { expect: ok('student_ok') });
addScan('ok_fresher_utf8', 'Fresher pass with a multi-byte name.', makeScan('fresher_utf8'), { expect: ok('fresher_utf8') });
addScan('ok_previous_key', 'Credential signed with the previous key version.', makeScan('student_prev_key'), { expect: ok('student_prev_key') });

// Android Keystore does not normalise s, so verifiers must accept both halves.
{
  const c = credentials.get('student_ok');
  const priv = devices.get('dev_a');
  const ts = NOW - 5;
  const base = signScan(priv, ts, c.bytes);
  for (const [label, high] of [['low_s', false], ['high_s', true]]) {
    const sig = withS(base, high);
    assert(nodeVerify(publicKey(priv), cat(CTX_SCAN, u64be(ts), c.bytes), sig));
    addScan(`ok_device_sig_${label}`, `Device signature with ${high ? 'high' : 'low'} s.`, qrText(envelope(c.bytes, c.collegeSig, ts, sig)), { expect: ok('student_ok') });
  }
}

// --- timestamp window (max_age 45, max_future 10)
addScan('ok_age_45s', 'now - ts == 45 is the oldest accepted scan.', makeScan('student_ok', { ts: NOW - 45 }), { expect: ok('student_ok') });
addScan('clock_age_46s', 'now - ts == 46 is stale.', makeScan('student_ok', { ts: NOW - 46 }), { expect: fail('CLOCK_MISMATCH') });
addScan('ok_future_10s', 'ts - now == 10 is the furthest accepted future skew.', makeScan('student_ok', { ts: NOW + 10 }), { expect: ok('student_ok') });
addScan('clock_future_11s', 'ts - now == 11 is rejected.', makeScan('student_ok', { ts: NOW + 11 }), { expect: fail('CLOCK_MISMATCH') });

// --- expiry (exp is exclusive)
addScan('expired', 'Credential expired 20 days ago, fresh timestamp.', makeScan('student_expired'), { expect: fail('EXPIRED') });
addScan('ok_one_second_before_exp', 'now == exp - 1 is still valid.', makeScan('student_exp_edge', { ts: NOW - 5 }), { now: NOW - 1, expect: ok('student_exp_edge') });
addScan('expired_at_exp', 'now == exp is expired.', makeScan('student_exp_edge', { ts: NOW - 5 }), { now: NOW, expect: fail('EXPIRED') });

// --- signature failures
{
  const good = makeScan('student_ok');
  const c = good.cred;

  const tampered = Buffer.from(c.bytes);
  const at = tampered.indexOf(Buffer.from('Sample'));
  assert(at > 0);
  tampered[at] = 'T'.charCodeAt(0); // "Tample Student": same length, still parses
  const tamperedEnv = envelope(tampered, c.collegeSig, good.ts, signScan(devices.get('dev_a'), good.ts, tampered));
  addScan('bad_college_sig_tampered_name', 'Name edited after the college signed; device re-signed the edited bytes.', qrText(tamperedEnv), { expect: fail('BAD_COLLEGE_SIG') });

  const flipped = Buffer.from(c.collegeSig);
  flipped[63] ^= 0x01;
  addScan('bad_college_sig_flipped_bit', 'One bit flipped in the college signature.', qrText(envelope(c.bytes, flipped, good.ts, signScan(devices.get('dev_a'), good.ts, c.bytes))), { expect: fail('BAD_COLLEGE_SIG') });

  const wrongDevice = signScan(devices.get('dev_b'), good.ts, c.bytes);
  addScan('bad_device_sig_wrong_key', 'Timestamp signed by a key that is not the one in the credential.', qrText(envelope(c.bytes, c.collegeSig, good.ts, wrongDevice)), { expect: fail('BAD_DEVICE_SIG') });

  const realSig = signScan(devices.get('dev_a'), good.ts, c.bytes);
  addScan('bad_device_sig_tampered_ts', 'Timestamp moved by one second after signing.', qrText(envelope(c.bytes, c.collegeSig, good.ts + 1, realSig)), { expect: fail('BAD_DEVICE_SIG') });
}

// --- key and version handling
addScan('unknown_key_version', 'kv 3 is not in the scanner keyset.', makeScan('student_unknown_key'), { expect: fail('UNKNOWN_KEY_VERSION') });
addScan('ok_when_keyset_has_kv3', 'The same credential is accepted once the scanner has kv 3.', makeScan('student_unknown_key'), { keyset: [1, 2, 3], expect: ok('student_unknown_key') });
addScan('unsupported_credential_version', 'Credential field v is 2.', makeScan('student_future_version'), { expect: fail('UNSUPPORTED_VERSION') });
{
  const good = makeScan('student_ok');
  addScan('unsupported_qr_version', 'QR prefix DC2. instead of DC1.', qrText(good.env, 2), { expect: fail('UNSUPPORTED_VERSION') });
  addScan('malformed_wrong_prefix', 'Prefix is not DC<digits>.', 'XX1.' + b64u(good.env), { expect: fail('MALFORMED') });
  addScan('malformed_empty', 'Empty string.', '', { expect: fail('MALFORMED') });
  addScan('malformed_not_base64url', 'Body contains characters outside the base64url alphabet.', 'DC1.@@@@@@@@', { expect: fail('MALFORMED') });
  addScan('malformed_truncated', 'Body cut in half.', 'DC1.' + b64u(good.env).slice(0, Math.floor(b64u(good.env).length / 2)), { expect: fail('MALFORMED') });
  addScan('malformed_trailing_bytes', 'One extra byte after the CBOR envelope.', 'DC1.' + b64u(cat(good.env, [0x00])), { expect: fail('MALFORMED') });

  const shortSig = cArr([cBstr(good.cred.bytes), cBstr(good.cred.collegeSig.subarray(0, 63)), cUint(good.ts), cBstr(signScan(devices.get('dev_a'), good.ts, good.cred.bytes))]);
  addScan('malformed_short_signature', 'College signature is 63 bytes.', qrText(shortSig), { expect: fail('MALFORMED') });

  const missing = cArr([cBstr(missingFieldCred.bytes), cBstr(missingFieldCred.collegeSig), cUint(good.ts), cBstr(signScan(devices.get('dev_a'), good.ts, missingFieldCred.bytes))]);
  addScan('malformed_credential_missing_exp', 'Correctly signed credential with field 11 (exp) missing.', qrText(missing), { expect: fail('MALFORMED') });
}

// --- revocation
const revocationDefs = [
  { id: 'rl_empty', kv: 2, seq: 5, iat: NOW - 600, entries: [] },
  { id: 'rl_revokes_1042', kv: 2, seq: 6, iat: NOW - 600, entries: [[999, IAT + 5000], [1042, IAT + 1000]] },
  { id: 'rl_revokes_1042_at_iat', kv: 2, seq: 7, iat: NOW - 600, entries: [[1042, IAT]] },
  { id: 'rl_1042_before_iat', kv: 2, seq: 8, iat: NOW - 600, entries: [[1042, IAT - 1]] },
  { id: 'rl_other_student', kv: 1, seq: 9, iat: NOW - 600, entries: [[7, IAT + 1000]] },
];

function makeRevocation({ kv, seq, iat, entries }) {
  const payload = cMap([
    [0, cUint(1)],
    [1, cUint(kv)],
    [2, cUint(seq)],
    [3, cUint(iat)],
    [4, cArr(entries.map(([sid, at]) => cArr([cUint(sid), cUint(at)])))],
  ]);
  const sig = checkedSign(college.get(kv), cat(CTX_REVO, payload));
  return { payload, sig, encoded: 'DR1.' + b64u(cArr([cBstr(payload), cBstr(sig)])) };
}

const revocationLists = revocationDefs.map((def) => {
  const r = makeRevocation(def);
  return { id: def.id, kv: def.kv, seq: def.seq, iat: def.iat, entries: def.entries, payload_hex: hex(r.payload), sig_hex: hex(r.sig), encoded: r.encoded };
});

const revocationCases = [];
for (const rl of revocationLists) revocationCases.push({ id: `${rl.id}_valid`, encoded: rl.encoded, keyset: [1, 2], expect: { result: 'OK', seq: rl.seq, iat: rl.iat, entries: rl.entries } });
{
  const rl = revocationLists[1];
  const body = Buffer.from(rl.encoded.slice(3), 'base64url');
  const bad = Buffer.from(body);
  bad[bad.length - 1] ^= 0x01;
  revocationCases.push({ id: 'rl_bad_signature', encoded: 'DR1.' + b64u(bad), keyset: [1, 2], expect: { result: 'BAD_SIGNATURE' } });
  revocationCases.push({ id: 'rl_unknown_key', encoded: rl.encoded, keyset: [1], expect: { result: 'UNKNOWN_KEY_VERSION' } });
  revocationCases.push({ id: 'rl_wrong_prefix', encoded: 'DX1.' + b64u(body), keyset: [1, 2], expect: { result: 'MALFORMED' } });
  revocationCases.push({ id: 'rl_truncated', encoded: 'DR1.' + b64u(body).slice(0, 20), keyset: [1, 2], expect: { result: 'MALFORMED' } });
}

const byId = new Map(revocationLists.map((r) => [r.id, r]));
const attach = (caseId, rlId, expect) => {
  const base = verifyCases.find((c) => c.id === 'ok_basic');
  verifyCases.push({ ...base, id: caseId, description: `ok_basic scan checked against list ${rlId}.`, revocation: byId.get(rlId).encoded, expect });
};
attach('revoked', 'rl_revokes_1042', { result: 'REVOKED' });
attach('revoked_at_iat', 'rl_revokes_1042_at_iat', { result: 'REVOKED' });
attach('not_revoked_reissued_after', 'rl_1042_before_iat', ok('student_ok'));
attach('not_revoked_other_student', 'rl_other_student', ok('student_ok'));
attach('not_revoked_empty_list', 'rl_empty', ok('student_ok'));

// ---------------------------------------------------------------- output

const keyEntry = (priv) => ({ private_hex: hex(priv), public_hex: hex(publicKey(priv)) });
const out = {
  spec: 'Digital Campus ID credential format v1 (docs/credential-spec.md)',
  warning: 'TEST KEYS ONLY. Generated by tools/gen-vectors/gen.mjs; do not edit by hand.',
  policy: POLICY,
  contexts: { cred_hex: hex(CTX_CRED), scan_hex: hex(CTX_SCAN), revo_hex: hex(CTX_REVO) },
  reference_now: NOW,
  keys: {
    college: [...college].map(([kv, priv]) => ({ kv, ...keyEntry(priv) })),
    devices: [...devices].map(([name, priv]) => ({ name, ...keyEntry(priv) })),
  },
  keyset_json: {
    v: 1,
    current: 2,
    keys: [1, 2].map((kv) => ({ kv, alg: 'ES256', pub: b64u(publicKey(college.get(kv))) })),
  },
  credentials: [...credentials.values()].map((c) => ({
    id: c.id,
    description: c.description,
    fields: {
      v: c.fields.v, kv: c.fields.kv, sid: c.fields.sid, roll: c.fields.roll, name: c.fields.name.normalize('NFC'), branch: c.fields.branch,
      year: c.fields.year, pass: c.fields.pass, photo_hex: hex(c.fields.photo), dpk_hex: hex(c.dpk), iat: c.fields.iat, exp: c.fields.exp,
    },
    cbor_hex: hex(c.bytes),
    college_sig_hex: hex(c.collegeSig),
    signed_text: 'DK1.' + b64u(cArr([cBstr(c.bytes), cBstr(c.collegeSig)])),
  })),
  revocation_lists: revocationLists,
  revocation_cases: revocationCases,
  verify_cases: verifyCases,
};

const here = path.dirname(fileURLToPath(import.meta.url));
const target = path.resolve(here, '../../spec/test-vectors/v1.json');
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, JSON.stringify(out, null, 2) + '\n');

const lens = scanVectors.filter((s) => s.id.startsWith('ok_')).map((s) => s.qr_chars);
console.log(`wrote ${path.relative(process.cwd(), target)}`);
console.log(`${verifyCases.length} verify cases, ${revocationCases.length} revocation cases, ${credentials.size} credentials`);
console.log(`QR text length for accepted scans: min ${Math.min(...lens)}, max ${Math.max(...lens)} chars`);
for (const c of credentials.values()) console.log(`  credential ${c.id}: ${c.bytes.length} bytes`);
