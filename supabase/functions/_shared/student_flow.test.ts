// Student login, enrolment and pass issuing on a real Postgres (PGlite), through the same handlers the local
// server uses, ending with the check that matters: a pass the server issues verifies as a scan.
//   npm test            (from supabase/functions)

import assert from 'node:assert/strict';
import test from 'node:test';
import { p256 } from '@noble/curves/p256';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import type { PGlite } from '@electric-sql/pglite';

import { createLocalDatabase, pgliteDb } from '../dev/local_db.ts';
import { devCollegeSigner } from '../dev/dev_signer.ts';
import { buildScanQr, collegeSigningInput, decodeCredential, parseSignedCredential, toBase64Url, verifyEcdsa, verifyScan } from './credential.ts';
import { handleEnrol, handleEnrolmentStatus } from './enrolment.ts';
import { handleIssueCredential } from './issue_credential.ts';
import { PgStudentStore } from './pg_student_store.ts';
import { hashToken } from './scanner_sync.ts';
import { authenticate, handleRequestOtp, handleSignOut, handleVerifyOtp } from './student_auth.ts';

const NOW_S = 1793118000;
const signer = devCollegeSigner();

let pg: PGlite;
let store: PgStudentStore;
const sent: Array<{ email: string; code: string }> = [];
let signerFails = false;

const post = (body: unknown, token?: string, method = 'POST') =>
  new Request('https://example.test/fn', {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: method === 'GET' ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  });

const authDeps = (exposeOtp = true) => ({ store, exposeOtp, deliver: (email: string, code: string) => void sent.push({ email, code }) });
const requestOtp = (email: unknown, exposeOtp = true) => handleRequestOtp(post({ email }), authDeps(exposeOtp));
const verifyOtp = (email: unknown, otp: unknown) => handleVerifyOtp(post({ email, otp }), authDeps());
const enrol = (body: unknown, token?: string) => handleEnrol(post(body, token), { store });
const status = (token?: string) => handleEnrolmentStatus(post(undefined, token, 'GET'), { store });
const issue = (body: unknown, token?: string) =>
  handleIssueCredential(post(body, token), {
    store,
    now: () => NOW_S,
    signer: { kv: signer.kv, sign: (m) => (signerFails ? Promise.reject(new Error('KMS is down')) : signer.sign(m)) },
  });

const j = async (res: Response) => (await res.json()) as Record<string, any>;

/** Plausible-looking JPEG bytes: the signature the server checks, then filler that differs by [seed]. */
function photoBase64(seed: number, size = 3000): string {
  const bytes = new Uint8Array(size);
  bytes.set([0xff, 0xd8, 0xff, 0xe0]);
  for (let i = 4; i < size; i++) bytes[i] = (i * 31 + seed * 17) & 0xff;
  return Buffer.from(bytes).toString('base64');
}

const collegePublic = () => {
  const vectors = JSON.parse(readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8')) as { keys: { college: Array<{ kv: number; private_hex: string }> } };
  const entry = vectors.keys.college.find((k) => k.kv === signer.kv)!;
  return p256.getPublicKey(hexToBytes(entry.private_hex), true);
};
const newDevice = () => {
  const priv = p256.utils.randomPrivateKey();
  return { priv, pub: p256.getPublicKey(priv, true) };
};
const keyOf = (d: { pub: Uint8Array }) => toBase64Url(d.pub);

async function addStudent(roll: string, email: string, name = 'Test Student', branch = 'CSE', year = 2): Promise<number> {
  const r = await pg.query<{ id: string }>('insert into public.students (roll_number, name, branch, year, college_email) values ($1,$2,$3,$4,$5) returning id::text as id', [roll, name, branch, year, email]);
  return Number(r.rows[0].id);
}

/** Logs in through the real handlers and returns the session token. */
async function login(email: string): Promise<string> {
  const code = (await j(await requestOtp(email))).dev_otp as string;
  await pg.exec(`update public.dev_otps set created_at = now() - interval '1 minute' where email = '${email}'`);
  return (await j(await verifyOtp(email, code))).access_token as string;
}

async function approve(studentId: number) {
  await pg.exec(`update public.enrolments set status = 'approved', reviewed_at = now() where student_id = ${studentId}`);
}

test.before(async () => {
  pg = await createLocalDatabase();
  store = new PgStudentStore(pgliteDb(pg));
});
test.after(async () => {
  await pg.close();
});
test.beforeEach(async () => {
  sent.length = 0;
  signerFails = false;
  await pg.exec(`
    delete from public.dev_otps; delete from public.dev_sessions; delete from public.devices; delete from public.enrolments; delete from public.dev_photos;
    delete from public.students where roll_number <> '25071A0001'; update public.students set status = 'active', phone = null, name = 'Sample Student';`);
});

test('asking for a login code', async (t) => {
  await t.test('only roster emails get one, and bad emails are refused', async () => {
    for (const bad of [undefined, '', 'nobody', 'a@b', 5, null]) assert.equal((await requestOtp(bad)).status, 400, String(bad));
    const res = await requestOtp('stranger@elsewhere.org');
    assert.equal(res.status, 404);
    assert.deepEqual(await j(res), { error: 'not_on_roster' });
    assert.equal(sent.length, 0);
  });

  await t.test('sends a six-digit code, and in demo mode also shows it', async () => {
    const res = await requestOtp('25071A0001@VNRVJIET.in ');
    const body = await j(res);
    assert.equal(res.status, 200);
    assert.match(body.dev_otp, /^\d{6}$/);
    assert.deepEqual(sent, [{ email: '25071a0001@vnrvjiet.in', code: body.dev_otp }]);
  });

  await t.test('outside demo mode the code is not in the reply', async () => {
    const body = await j(await requestOtp('25071a0001@vnrvjiet.in', false));
    assert.deepEqual(body, { sent: true });
    assert.equal(sent.length, 1);
  });

  await t.test('the code is stored hashed, never as typed', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    const stored = (await pg.query<{ code_hash: string }>('select code_hash from public.dev_otps')).rows[0].code_hash;
    assert.notEqual(stored, code);
    assert.match(stored, /^[0-9a-f]{64}$/);
  });

  await t.test('asking again within 30 seconds is refused, and later is fine', async () => {
    await requestOtp('25071a0001@vnrvjiet.in');
    const again = await requestOtp('25071a0001@vnrvjiet.in');
    assert.equal(again.status, 429);
    assert.ok((await j(again)).retry_after_s > 0);
    await pg.exec("update public.dev_otps set created_at = now() - interval '31 seconds'");
    assert.equal((await requestOtp('25071a0001@vnrvjiet.in')).status, 200);
  });
});

test('logging in with the code', async (t) => {
  await t.test('the right code gives a session, once', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    const res = await verifyOtp('25071a0001@vnrvjiet.in', code);
    const body = await j(res);

    assert.equal(res.status, 200);
    assert.match(body.access_token, /^[A-Za-z0-9_-]{43}$/);
    assert.deepEqual(body.student, { name: 'Sample Student', roll_number: '25071A0001', branch: 'CSE-AIML', year: 2, email: '25071a0001@vnrvjiet.in', profile_complete: true });
    assert.equal((await verifyOtp('25071a0001@vnrvjiet.in', code)).status, 401, 'a code works once');

    const stored = (await pg.query<{ token_hash: string }>('select token_hash from public.dev_sessions')).rows[0].token_hash;
    assert.equal(stored, hashToken(body.access_token), 'only the hash of the token is kept');
  });

  await t.test('a wrong code is refused and counted; five wrong tries lock it, even for the right code', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) assert.equal((await verifyOtp('25071a0001@vnrvjiet.in', wrong)).status, 401);
    const locked = await verifyOtp('25071a0001@vnrvjiet.in', code);
    assert.equal(locked.status, 429);
    assert.deepEqual(await j(locked), { error: 'too_many_attempts' });
  });

  await t.test('a code is only good for the email it was sent to', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    assert.equal((await verifyOtp('25071a0002@vnrvjiet.in', code)).status, 401);
    assert.equal((await pg.query('select 1 from public.students where roll_number = $1', ['25071A0002'])).rows.length, 0, 'and nobody is signed up by it');
  });

  await t.test('an expired code, a code never asked for, and nonsense all get the same answer', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    await pg.exec("update public.dev_otps set expires_at = now() - interval '1 second'");
    const answers = [
      await verifyOtp('25071a0001@vnrvjiet.in', code),
      await verifyOtp('two@college.test', '123456'),
      await verifyOtp('25071a0001@vnrvjiet.in', 'abcdef'),
      await verifyOtp(5, 5),
    ];
    for (const a of answers) {
      assert.equal(a.status, 401);
      assert.deepEqual(await j(a), { error: 'invalid_or_expired_otp' });
    }
  });

  await t.test('spaces in the code are forgiven', async () => {
    const code = (await j(await requestOtp('25071a0001@vnrvjiet.in'))).dev_otp as string;
    assert.equal((await verifyOtp('25071a0001@vnrvjiet.in', `${code.slice(0, 3)} ${code.slice(3)}`)).status, 200);
  });
});

test('sessions', async (t) => {
  await t.test('a token identifies its student; a wrong or expired one does not', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    const caller = await authenticate(post({}, token), store);
    assert.equal(caller?.studentId, 1);
    assert.equal(await authenticate(post({}, 'x'.repeat(43)), store), null);
    assert.equal(await authenticate(post({}), store), null);

    await pg.exec("update public.dev_sessions set expires_at = now() - interval '1 second'");
    assert.equal(await authenticate(post({}, token), store), null);
  });

  await t.test('signing out ends the session', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    assert.equal((await handleSignOut(post({}, token), { store })).status, 200);
    assert.equal(await authenticate(post({}, token), store), null);
    assert.equal((await handleSignOut(post({}), { store })).status, 401);
  });
});

test('enrolling', async (t) => {
  await t.test('needs a login', async () => {
    assert.equal((await enrol({ phone: '9876543210', photo_base64: photoBase64(1) })).status, 401);
    assert.equal((await status()).status, 401);
  });

  await t.test('a bad phone number or photo is refused', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    for (const phone of [undefined, '', '12345', 'call me', '+1234567890123456', 5]) {
      assert.equal((await enrol({ phone, photo_base64: photoBase64(1) }, token)).status, 400, String(phone));
    }
    const tooBig = Buffer.alloc(1_600_000, 0xff).toString('base64');
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(2000)]).toString('base64');
    const notAnImage = Buffer.alloc(3000, 0x41).toString('base64');
    for (const photo of [undefined, '', '!!!not base64!!!', Buffer.alloc(100, 0xff).toString('base64'), tooBig, notAnImage, 12]) {
      assert.equal((await enrol({ phone: '9876543210', photo_base64: photo }, token)).status, 400, String(photo).slice(0, 20));
    }
    assert.equal((await enrol({ phone: '9876543210', photo_base64: png }, token)).status, 200, 'a PNG is fine');
  });

  await t.test('saves the phone and photo, and approves at once: the one-time code already proved who this is', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    const photo = photoBase64(1);
    const res = await enrol({ phone: '+91 98765-43210', photo_base64: photo }, token);

    assert.equal(res.status, 200);
    assert.deepEqual(await j(res), { status: 'approved', flags: [] });
    const row = (await pg.query<{ phone: string; status: string; photo_hash: Uint8Array; reviewed_at: unknown }>('select phone, status, photo_hash, reviewed_at from public.enrolments')).rows[0];
    assert.equal(row.phone, '+919876543210');
    assert.equal(row.status, 'approved');
    assert.ok(row.reviewed_at, 'the approval is dated');
    assert.equal(bytesToHex(new Uint8Array(row.photo_hash)), bytesToHex(sha256(Buffer.from(photo, 'base64')).slice(0, 16)), 'the pass will carry the first 16 bytes of the photo\'s SHA-256');
    assert.equal((await pg.query('select 1 from public.dev_photos where student_id = 1')).rows.length, 1);
    assert.equal((await pg.query<{ phone: string }>('select phone from public.students where id = 1')).rows[0].phone, '+919876543210');
  });

  await t.test('status goes from none to approved, with no admin in between', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    assert.equal((await j(await status(token))).status, 'none');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1) }, token);
    const after = await j(await status(token));
    assert.equal(after.status, 'approved');
    assert.equal(after.student.name, 'Sample Student');
    assert.equal(after.student.profile_complete, true);
  });

  await t.test('sending again after a rejection replaces the first submission, not adds one', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1) }, token);
    await pg.exec("update public.enrolments set status = 'rejected'");
    await enrol({ phone: '9123456780', photo_base64: photoBase64(2) }, token);
    const rows = (await pg.query<{ phone: string }>('select phone from public.enrolments')).rows;
    assert.deepEqual(rows.map((r) => r.phone), ['9123456780']);
  });

  await t.test('an approved student cannot swap their photo; a rejected one can try again', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1) }, token);
    await approve(1);
    assert.equal((await enrol({ phone: '9876543210', photo_base64: photoBase64(2) }, token)).status, 409);

    await pg.exec("update public.enrolments set status = 'rejected'");
    const again = await enrol({ phone: '9876543210', photo_base64: photoBase64(3) }, token);
    assert.equal(again.status, 200);
    assert.equal((await j(again)).status, 'pending');
  });

  await t.test('the same photo from two students is flagged for the admin to look at, not blocked', async () => {
    await addStudent('25071A0002', '25071a0002@vnrvjiet.in', 'Second');
    const first = await login('25071a0001@vnrvjiet.in');
    const second = await login('25071a0002@vnrvjiet.in');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(7) }, first);
    const res = await enrol({ phone: '9123456780', photo_base64: photoBase64(7) }, second);

    assert.deepEqual(await j(res), { status: 'approved', flags: ['duplicate'] });
  });

  await t.test('a rejected student who sends a new photo waits for an admin instead of being approved again', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1) }, token);
    await pg.exec("update public.enrolments set status = 'rejected'");
    assert.deepEqual(await j(await enrol({ phone: '9876543210', photo_base64: photoBase64(2) }, token)), { status: 'pending', flags: [] });
  });
});

test('issuing a pass', async (t) => {
  /** A student who is logged in, enrolled and approved, ready to ask for a pass. */
  async function approvedStudent(photoSeed = 1) {
    const token = await login('25071a0001@vnrvjiet.in');
    await enrol({ phone: '9876543210', photo_base64: photoBase64(photoSeed) }, token);
    await approve(1);
    return token;
  }

  await t.test('needs a login', async () => {
    assert.equal((await issue({ device_public_key: keyOf(newDevice()) })).status, 401);
  });

  await t.test('refuses a key that is not a real P-256 key', async () => {
    const token = await approvedStudent();
    const good = newDevice().pub;
    const offCurve = new Uint8Array(33).fill(0xff);
    offCurve[0] = 0x02;
    const uncompressed = p256.getPublicKey(newDevice().priv, false);
    for (const key of [undefined, '', 'not-base64!', toBase64Url(good.slice(0, 32)), toBase64Url(offCurve), toBase64Url(uncompressed), toBase64Url(Uint8Array.from([0x05, ...good.slice(1)])), 7]) {
      assert.equal((await issue({ device_public_key: key }, token)).status, 422, String(key));
    }
  });

  await t.test('not before there is an approved enrolment, and the student is told why', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    const none = await issue({ device_public_key: keyOf(newDevice()) }, token);
    assert.equal(none.status, 403);
    assert.deepEqual(await j(none), { error: 'not_approved', status: 'none' });

    await enrol({ phone: '9876543210', photo_base64: photoBase64(1) }, token);
    await pg.exec("update public.enrolments set status = 'pending'");
    assert.deepEqual(await j(await issue({ device_public_key: keyOf(newDevice()) }, token)), { error: 'not_approved', status: 'pending' });

    await pg.exec("update public.enrolments set status = 'rejected'");
    assert.deepEqual(await j(await issue({ device_public_key: keyOf(newDevice()) }, token)), { error: 'not_approved', status: 'rejected' });
  });

  await t.test('not for a student who has been paused or revoked', async () => {
    const token = await approvedStudent();
    for (const state of ['paused', 'revoked']) {
      await pg.exec(`update public.students set status = '${state}' where id = 1`);
      const res = await issue({ device_public_key: keyOf(newDevice()) }, token);
      assert.equal(res.status, 403, state);
      assert.deepEqual(await j(res), { error: 'student_not_active' });
    }
    assert.equal((await pg.query('select 1 from public.devices')).rows.length, 0);
  });

  await t.test('a roster entry that does not fit the pass is refused, not truncated', async () => {
    const token = await approvedStudent();
    await pg.exec(`update public.students set name = '${'😀'.repeat(20)}' where id = 1`); // 20 characters, 80 bytes
    assert.equal((await issue({ device_public_key: keyOf(newDevice()) }, token)).status, 422);
  });

  await t.test('the pass is signed by the college, bound to the phone, and carries the photo hash', async () => {
    const token = await approvedStudent(5);
    const device = newDevice();
    const res = await issue({ device_public_key: keyOf(device) }, token);
    const body = await j(res);

    assert.equal(res.status, 200);
    assert.equal(body.server_time, NOW_S);
    assert.equal(body.key_version, 2);
    const signed = parseSignedCredential(body.signed_credential)!;
    assert.ok(verifyEcdsa(signer ? p256.getPublicKey(hexKey(), true) : new Uint8Array(), collegeSigningInput(signed.credentialBytes), signed.collegeSig), 'the college signature checks out');

    const c = decodeCredential(signed.credentialBytes);
    assert.deepEqual([c.v, c.kv, c.sid, c.roll, c.name, c.branch, c.year, c.pass], [1, 2, 1, '25071A0001', 'Sample Student', 'CSE-AIML', 2, 0]);
    assert.equal(bytesToHex(c.dpk), bytesToHex(device.pub));
    assert.equal(bytesToHex(c.photo), bytesToHex(sha256(Buffer.from(photoBase64(5), 'base64')).slice(0, 16)));
    assert.equal(c.iat, NOW_S);
    assert.equal(c.exp - c.iat, 180 * 86400, 'about a semester, within the 200 days the spec allows');
  });

  await t.test('a QR the phone builds from that pass is accepted by the scanner\'s own verification', async () => {
    const token = await approvedStudent();
    const device = newDevice();
    const signed = parseSignedCredential((await j(await issue({ device_public_key: keyOf(device) }, token))).signed_credential)!;

    const qr = buildScanQr(signed, NOW_S - 5, device.priv);
    const outcome = verifyScan(qr, { now: NOW_S, keys: new Map([[2, p256.getPublicKey(hexKey(), true)]]) });

    assert.equal(outcome.ok, true);
    assert.equal(outcome.ok && outcome.credential.name, 'Sample Student');

    const stolen = verifyScan(buildScanQr(signed, NOW_S - 5, newDevice().priv), { now: NOW_S, keys: new Map([[2, p256.getPublicKey(hexKey(), true)]]) });
    assert.deepEqual(stolen, { ok: false, code: 'BAD_DEVICE_SIG' }, 'a copy of the pass without the phone\'s key is no use');
  });

  await t.test('the name is put in its standard Unicode form', async () => {
    const token = await approvedStudent();
    await pg.exec("update public.students set name = 'Srāvya Ñandini' where id = 1"); // letters + combining marks
    const signed = parseSignedCredential((await j(await issue({ device_public_key: keyOf(newDevice()) }, token))).signed_credential)!;
    assert.equal(decodeCredential(signed.credentialBytes).name, 'Srāvya Ñandini'.normalize('NFC'));
  });

  await t.test('asking again with the same phone key keeps one active device', async () => {
    const token = await approvedStudent();
    const device = newDevice();
    await issue({ device_public_key: keyOf(device) }, token);
    await issue({ device_public_key: keyOf(device) }, token);
    const devices = (await pg.query<{ revoked_at: unknown }>('select revoked_at from public.devices')).rows;
    assert.equal(devices.length, 1);
    assert.equal(devices[0].revoked_at, null);
  });

  await t.test('a new phone replaces the old one: the old device is revoked and the new pass is not caught by that', async () => {
    const token = await approvedStudent();
    const oldPhone = newDevice();
    const newPhone = newDevice();
    await issue({ device_public_key: keyOf(oldPhone) }, token);
    const res = await issue({ device_public_key: keyOf(newPhone) }, token);

    const devices = (await pg.query<{ public_key: string; revoked: boolean; revoked_at: string | null }>(
      "select encode(device_public_key, 'hex') as public_key, revoked_at is not null as revoked, extract(epoch from revoked_at)::bigint::text as revoked_at from public.devices order by id",
    )).rows;
    assert.deepEqual(devices.map((d) => [d.public_key, d.revoked]), [[bytesToHex(oldPhone.pub), true], [bytesToHex(newPhone.pub), false]]);

    const c = decodeCredential(parseSignedCredential((await j(res)).signed_credential)!.credentialBytes);
    assert.ok(c.iat > Number(devices[0].revoked_at), `iat ${c.iat} must be after the revocation at ${devices[0].revoked_at}, or the new pass would be revoked at once`);
  });

  await t.test('if signing fails nothing changes: the old phone stays valid', async () => {
    const token = await approvedStudent();
    const oldPhone = newDevice();
    await issue({ device_public_key: keyOf(oldPhone) }, token);

    signerFails = true;
    const originalError = console.error;
    console.error = () => {};
    try {
      assert.equal((await issue({ device_public_key: keyOf(newDevice()) }, token)).status, 500);
    } finally {
      console.error = originalError;
    }

    const devices = (await pg.query<{ revoked_at: unknown }>('select revoked_at from public.devices')).rows;
    assert.equal(devices.length, 1);
    assert.equal(devices[0].revoked_at, null, 'the old device was not revoked by a failed attempt');
  });
});

function hexKey(): Uint8Array {
  // the college test key kv 2, the same one devCollegeSigner uses
  const vectors = JSON.parse(readFileSyncVectors()) as { keys: { college: Array<{ kv: number; private_hex: string }> } };
  const hex = vectors.keys.college.find((k) => k.kv === 2)!.private_hex;
  return Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
}

import { readFileSync } from 'node:fs';
function readFileSyncVectors(): string {
  return readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8');
}

test('signing up with a roll-number email', async (t) => {
  const EMAIL = '25071a66j1@vnrvjiet.in';
  const profile = { name: '  Test   Student ', branch: 'cse-ds', year: 2 };

  await t.test('only <roll number>@<college domain> may sign up', async () => {
    for (const email of ['stranger@vnrvjiet.in', '25071a66j1@gmail.com', '25071a66j1@vnrvjiet.in.evil.com', '25071a66j1@evil.com', '2507a66j1@vnrvjiet.in', '25071a66j1x@vnrvjiet.in', '@vnrvjiet.in', 'vnrvjiet.in']) {
      assert.equal((await requestOtp(email)).status, ['@vnrvjiet.in', 'vnrvjiet.in'].includes(email) ? 400 : 404, email);
    }
    assert.equal(sent.length, 0);
    assert.equal((await requestOtp('ADM26-00317@vnrvjiet.in')).status, 200, "a fresher's admission number is a roll number too");
  });

  await t.test('another college domain can be configured', async () => {
    const deps = { ...authDeps(), emailDomain: 'college.test' };
    assert.equal((await handleRequestOtp(post({ email: '25071a66j1@college.test' }), deps)).status, 200);
    assert.equal((await handleRequestOtp(post({ email: EMAIL }), deps)).status, 404);
  });

  await t.test('a new roll number is signed up by its one-time code, with a profile still to fill in', async () => {
    const code = (await j(await requestOtp(EMAIL))).dev_otp as string;
    assert.equal((await pg.query('select 1 from public.students where roll_number = $1', ['25071A66J1'])).rows.length, 0, 'nothing is created by only asking for a code');

    const body = await j(await verifyOtp(EMAIL, code));
    assert.equal(body.student.roll_number, '25071A66J1');
    assert.equal(body.student.profile_complete, false);
    const row = (await pg.query<{ college_email: string; profile_complete: boolean }>('select college_email, profile_complete from public.students where roll_number = $1', ['25071A66J1'])).rows[0];
    assert.deepEqual(row, { college_email: EMAIL, profile_complete: false });
  });

  await t.test('enrolling needs name, branch and year the first time, and then approves at once', async () => {
    const token = await login(EMAIL);
    const photo_base64 = photoBase64(1);

    const without = await enrol({ phone: '9876543210', photo_base64 }, token);
    assert.equal(without.status, 400);
    assert.deepEqual(await j(without), { error: 'bad_profile' });

    for (const bad of [{ name: '' }, { name: 'x'.repeat(65) }, { branch: '' }, { branch: 'x'.repeat(13) }, { year: 0 }, { year: 7 }, { year: 'two' }, { name: 'bad\u0007name' }]) {
      assert.equal((await enrol({ phone: '9876543210', photo_base64, ...profile, ...bad }, token)).status, 400, JSON.stringify(bad));
    }

    const res = await enrol({ phone: '9876543210', photo_base64, ...profile }, token);
    assert.deepEqual(await j(res), { status: 'approved', flags: [] });
    const row = (await pg.query<{ name: string; branch: string; year: number; profile_complete: boolean }>('select name, branch, year, profile_complete from public.students where roll_number = $1', ['25071A66J1'])).rows[0];
    assert.deepEqual(row, { name: 'Test Student', branch: 'CSE-DS', year: 2, profile_complete: true });
    const info = await j(await status(token));
    assert.equal(info.status, 'approved');
    assert.equal(info.student.profile_complete, true);
  });

  await t.test('a year sent as text is fine, and a rejection followed by a new photo needs no profile again', async () => {
    const token = await login(EMAIL);
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1), ...profile, year: '3' }, token);
    assert.equal((await pg.query<{ year: number }>('select year from public.students where roll_number = $1', ['25071A66J1'])).rows[0].year, 3);
    await pg.exec("update public.enrolments set status = 'rejected'");
    assert.equal((await enrol({ phone: '9876543210', photo_base64: photoBase64(2) }, token)).status, 200);
  });

  await t.test('once the profile is set, a later request cannot change who the student is', async () => {
    const token = await login(EMAIL);
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1), ...profile }, token);
    await pg.exec("update public.enrolments set status = 'rejected'");
    await enrol({ phone: '9876543210', photo_base64: photoBase64(2), name: 'Someone Else', branch: 'ECE', year: 4 }, token);
    const row = (await pg.query<{ name: string; branch: string; year: number }>('select name, branch, year from public.students where roll_number = $1', ['25071A66J1'])).rows[0];
    assert.deepEqual(row, { name: 'Test Student', branch: 'CSE-DS', year: 2 });
  });

  await t.test('the pass carries what the student gave, and a scanner accepts it', async () => {
    const token = await login(EMAIL);
    await enrol({ phone: '9876543210', photo_base64: photoBase64(1), ...profile }, token);
    const phone = newDevice();
    const res = await issue({ device_public_key: keyOf(phone) }, token);
    assert.equal(res.status, 200);
    const issued = parseSignedCredential((await j(res)).signed_credential)!;
    const credential = decodeCredential(issued.credentialBytes);
    assert.equal(credential.roll, '25071A66J1');
    assert.equal(credential.name, 'Test Student');
    assert.equal(credential.branch, 'CSE-DS');
    assert.equal(credential.year, 2);

    const qr = buildScanQr(issued, NOW_S, phone.priv);
    const outcome = verifyScan(qr, { now: NOW_S, keys: new Map([[signer.kv, collegePublic()]]) });
    assert.equal(outcome.ok, true);
  });

  await t.test('a stub profile is not enough for a pass', async () => {
    const token = await login(EMAIL);
    const res = await issue({ device_public_key: keyOf(newDevice()) }, token);
    assert.equal(res.status, 403, 'no enrolment yet');
  });

  await t.test('an existing roster student keeps the name, branch and year the college entered', async () => {
    const token = await login('25071a0001@vnrvjiet.in');
    const res = await enrol({ phone: '9876543210', photo_base64: photoBase64(1), name: 'Changed Name', branch: 'ECE', year: 5 }, token);
    assert.equal(res.status, 200);
    const row = (await pg.query<{ name: string; branch: string; year: number }>('select name, branch, year from public.students where roll_number = $1', ['25071A0001'])).rows[0];
    assert.deepEqual(row, { name: 'Sample Student', branch: 'CSE-AIML', year: 2 });
  });
});
