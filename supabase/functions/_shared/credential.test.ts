// Runs the shared test vectors against the TypeScript implementation.
//   npm test            (from supabase/functions, uses Node's built-in test runner)
// The Dart package credential_core runs the same vectors from spec/test-vectors/v1.json.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';

import {
  CTX_CRED,
  CTX_REVO,
  CTX_SCAN,
  buildScanQr,
  collegeSigningInput,
  decodeCredential,
  ecdsaDerToRaw,
  encodeCredential,
  encodeRevocationList,
  issueCredential,
  parseKeySet,
  parseSignedCredential,
  publicKeyOf,
  signEcdsa,
  verifyEcdsa,
  verifyRevocationList,
  verifyScan,
} from './credential.ts';
import type { Credential } from './credential.ts';

const hex = (b: Uint8Array) => Buffer.from(b).toString('hex');
const unhex = (s: string) => new Uint8Array(Buffer.from(s, 'hex'));

// deno-lint-ignore no-explicit-any
const V: any = JSON.parse(fs.readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8'));

const collegePub = new Map<number, Uint8Array>(V.keys.college.map((k: any) => [k.kv, unhex(k.public_hex)]));
const collegePriv = new Map<number, Uint8Array>(V.keys.college.map((k: any) => [k.kv, unhex(k.private_hex)]));
const devicePriv = new Map<string, Uint8Array>(V.keys.devices.map((k: any) => [k.name, unhex(k.private_hex)]));
const pubsFor = (kvs: number[]) => new Map(kvs.map((kv) => [kv, collegePub.get(kv)!]));

const toCredential = (f: any): Credential => ({
  v: f.v, kv: f.kv, sid: f.sid, roll: f.roll, name: f.name, branch: f.branch, year: f.year, pass: f.pass,
  photo: unhex(f.photo_hex), dpk: unhex(f.dpk_hex), iat: f.iat, exp: f.exp,
});

test('context strings', () => {
  assert.equal(hex(CTX_CRED), V.contexts.cred_hex);
  assert.equal(hex(CTX_SCAN), V.contexts.scan_hex);
  assert.equal(hex(CTX_REVO), V.contexts.revo_hex);
});

test('public keys derive from the test private keys', () => {
  for (const k of V.keys.college) assert.equal(hex(publicKeyOf(unhex(k.private_hex))), k.public_hex);
  for (const k of V.keys.devices) assert.equal(hex(publicKeyOf(unhex(k.private_hex))), k.public_hex);
});

test('key set document parses to the same keys', () => {
  const keys = parseKeySet(V.keyset_json);
  assert.equal(keys.size, 2);
  for (const [kv, pub] of keys) assert.equal(hex(pub), hex(collegePub.get(kv)!));
});

for (const c of V.credentials) {
  test(`credential ${c.id}: encoding, signature and delivery blob`, async () => {
    const fields = toCredential(c.fields);
    const bytes = encodeCredential(fields);
    assert.equal(hex(bytes), c.cbor_hex, 'deterministic CBOR must match byte for byte');

    // Both implementations use RFC 6979, so even the signature bytes must agree.
    assert.equal(hex(signEcdsa(collegePriv.get(fields.kv)!, collegeSigningInput(bytes))), c.college_sig_hex);
    assert.ok(verifyEcdsa(collegePub.get(fields.kv)!, collegeSigningInput(bytes), unhex(c.college_sig_hex)));

    const issued = await issueCredential(fields, async (m) => signEcdsa(collegePriv.get(fields.kv)!, m));
    assert.equal(issued.signedText, c.signed_text);
    const parsed = parseSignedCredential(c.signed_text)!;
    assert.equal(hex(parsed.credentialBytes), c.cbor_hex);
    assert.equal(hex(parsed.collegeSig), c.college_sig_hex);

    if (fields.v === 1) assert.deepEqual(decodeCredential(unhex(c.cbor_hex)), fields);
  });
}

test('ok_basic can be reproduced byte for byte from the credential and the device key', () => {
  const c = V.credentials.find((x: any) => x.id === 'student_ok');
  const qr = buildScanQr(
    { credentialBytes: unhex(c.cbor_hex), collegeSig: unhex(c.college_sig_hex) },
    V.reference_now - 5,
    devicePriv.get('dev_a')!,
  );
  assert.equal(qr, V.verify_cases.find((x: any) => x.id === 'ok_basic').qr);
});

for (const rl of V.revocation_lists) {
  test(`revocation list ${rl.id} re-encodes identically`, async () => {
    const encoded = await encodeRevocationList(
      { kv: rl.kv, seq: rl.seq, iat: rl.iat, entries: rl.entries },
      async (m) => signEcdsa(collegePriv.get(rl.kv)!, m),
    );
    assert.equal(encoded, rl.encoded);
  });
}

for (const c of V.revocation_cases) {
  test(`revocation case ${c.id}`, () => {
    const out = verifyRevocationList(c.encoded, pubsFor(c.keyset));
    if (c.expect.result === 'OK') {
      assert.ok(out.ok);
      if (out.ok) {
        assert.equal(out.list.seq, c.expect.seq);
        assert.equal(out.list.iat, c.expect.iat);
        assert.deepEqual(out.list.entries, c.expect.entries);
      }
    } else {
      assert.ok(!out.ok);
      if (!out.ok) assert.equal(out.code, c.expect.result);
    }
  });
}

const revocationById = new Map<string, string>(V.revocation_lists.map((r: any) => [r.id, r.encoded]));
for (const c of V.verify_cases) {
  test(`verify case ${c.id}`, () => {
    const keys = pubsFor(c.keyset);
    let revoked: Array<[number, number]> = [];
    if (c.revocation) {
      const list = verifyRevocationList(c.revocation, keys);
      assert.ok(list.ok, 'the list attached to a verify case must itself be valid');
      if (list.ok) revoked = list.list.entries;
    }
    const out = verifyScan(c.qr, {
      now: c.now,
      keys,
      revoked,
      maxAgeS: V.policy.max_age_s,
      maxFutureS: V.policy.max_future_s,
    });
    if (c.expect.result === 'OK') {
      assert.ok(out.ok, `expected OK, got ${out.ok ? 'OK' : out.code}`);
      if (out.ok) {
        const x = c.expect.credential;
        const got = out.credential;
        assert.deepEqual(
          { sid: got.sid, roll: got.roll, name: got.name, branch: got.branch, year: got.year, pass: got.pass, kv: got.kv, exp: got.exp },
          x,
        );
      }
    } else {
      assert.ok(!out.ok, 'expected a rejection');
      if (!out.ok) assert.equal(out.code, c.expect.result);
    }
  });
}

test('every revocation list used by a verify case exists', () => {
  for (const c of V.verify_cases) if (c.revocation) assert.ok([...revocationById.values()].includes(c.revocation));
});

test('DER signatures (Android Keystore, KMS) convert to raw and verify', () => {
  const c = V.credentials.find((x: any) => x.id === 'student_ok');
  const priv = devicePriv.get('dev_a')!;
  const keyObject = crypto.createPrivateKey({
    key: Buffer.concat([
      Buffer.from('308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420', 'hex'),
      Buffer.from(priv),
      Buffer.from('a144034200', 'hex'),
      Buffer.from(crypto.ECDH.convertKey(publicKeyOf(priv), 'prime256v1', undefined, undefined, 'uncompressed')),
    ]),
    format: 'der',
    type: 'pkcs8',
  });
  const message = Buffer.from('anything at all');
  for (let i = 0; i < 20; i++) {
    // random k each time, so this exercises both low-s and high-s outputs
    const der = crypto.sign('sha256', message, { key: keyObject, dsaEncoding: 'der' });
    const raw = ecdsaDerToRaw(new Uint8Array(der));
    assert.equal(raw.length, 64);
    assert.ok(verifyEcdsa(publicKeyOf(priv), new Uint8Array(message), raw));
  }
  assert.ok(c);
});
