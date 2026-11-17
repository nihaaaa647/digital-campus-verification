import assert from 'node:assert/strict';
import test from 'node:test';

import { ADMIN_COOKIE, LOCKOUT_SECONDS, MAX_FAILURES, SESSION_HOURS, createAdminAuth } from './admin_auth.ts';

const PASSWORD = 'correct-horse-battery';
let clock = 1_800_000_000_000;
const newAuth = () => createAdminAuth({ password: PASSWORD, now: () => clock });

const req = (path: string, init: RequestInit & { cookie?: string } = {}) => {
  const { cookie, headers, ...rest } = init;
  return new Request(`http://localhost${path}`, { ...rest, headers: { ...(headers as Record<string, string>), ...(cookie ? { cookie } : {}) } });
};
const form = (password: string) => ({ method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: `password=${encodeURIComponent(password)}` });

async function signIn(auth: ReturnType<typeof newAuth>): Promise<string> {
  const res = await auth.gate(req('/admin/login', form(PASSWORD)));
  const set = res!.headers.get('set-cookie')!;
  return set.split(';')[0];
}

test.beforeEach(() => {
  clock = 1_800_000_000_000;
});

test('without a login, nothing that holds student data is reachable', async (t) => {
  const auth = newAuth();

  await t.test('the admin address shows the sign-in page, and the page holds no data', async () => {
    const res = (await auth.gate(req('/admin')))!;
    assert.equal(res.status, 200);
    const html = await res.text();
    assert.match(html, /Admin password/);
    assert.ok(!html.includes('Roster'), 'it is the sign-in page, not the admin page');
  });

  await t.test('every API route and export is refused with 401', async () => {
    for (const [method, path] of [
      ['GET', '/admin/api/state'],
      ['GET', '/admin/api/exits.csv'],
      ['GET', '/admin/api/exits'],
      ['GET', '/admin/api/photo/1'],
      ['POST', '/admin/api/students'],
      ['POST', '/admin/api/enrolments/1/approve'],
      ['POST', '/admin/api/scanners/SC-NEW/code'],
      ['GET', '/_dev/scans'],
      ['GET', '/_dev/activation-code?scanner=SC-NEW'],
    ] as const) {
      const res = (await auth.gate(req(path, { method })))!;
      assert.equal(res.status, 401, `${method} ${path}`);
      assert.deepEqual(await res.json(), { error: 'unauthorized' });
    }
  });

  await t.test('the development pages ask for the login too', async () => {
    const res = (await auth.gate(req('/_dev/test-pass')))!;
    assert.match(await res.text(), /Admin password/);
  });

  await t.test("a scanner's token opens nothing: a guard cannot reach the admin website with the app's credentials", async () => {
    for (const path of ['/admin/api/state', '/admin/api/exits.csv', '/_dev/scans']) {
      const res = (await auth.gate(req(path, { headers: { Authorization: 'Bearer dev-token' } })))!;
      assert.equal(res.status, 401, path);
    }
  });

  await t.test('the old browser-popup password (HTTP Basic) is no longer a way in', async () => {
    const basic = `Basic ${Buffer.from(`admin:${PASSWORD}`).toString('base64')}`;
    assert.equal((await auth.gate(req('/admin/api/exits.csv', { headers: { Authorization: basic } })))!.status, 401);
  });

  await t.test('a made-up cookie is no way in', async () => {
    assert.equal((await auth.gate(req('/admin/api/state', { cookie: `${ADMIN_COOKIE}=abc` })))!.status, 401);
    assert.equal((await auth.gate(req('/admin/api/state', { cookie: `other=${PASSWORD}` })))!.status, 401);
  });
});

test('signing in', async (t) => {
  await t.test('the right password sets a session cookie the browser cannot read or send from another site', async () => {
    const auth = newAuth();
    const res = (await auth.gate(req('/admin/login', form(PASSWORD))))!;
    assert.equal(res.status, 303);
    assert.equal(res.headers.get('location'), '/admin');
    const cookie = res.headers.get('set-cookie')!;
    assert.match(cookie, new RegExp(`^${ADMIN_COOKIE}=[A-Za-z0-9_-]{40,}`));
    assert.match(cookie, /HttpOnly/);
    assert.match(cookie, /SameSite=Strict/);
    assert.match(cookie, /Path=\//);
    assert.match(cookie, new RegExp(`Max-Age=${SESSION_HOURS * 3600}`));
    assert.ok(!cookie.includes(PASSWORD), 'the cookie is not the password');
  });

  await t.test('with the cookie the admin may go on', async () => {
    const auth = newAuth();
    const cookie = await signIn(auth);
    for (const path of ['/admin', '/admin/api/state', '/admin/api/exits.csv', '/_dev/test-pass']) {
      assert.equal(await auth.gate(req(path, { cookie })), null, path);
    }
    assert.equal(await auth.gate(req('/admin/api/students', { method: 'POST', cookie })), null);
  });

  await t.test('a wrong password is refused with a message, and no cookie', async () => {
    const auth = newAuth();
    const res = (await auth.gate(req('/admin/login', form('nope'))))!;
    assert.equal(res.status, 401);
    assert.equal(res.headers.get('set-cookie'), null);
    assert.match(await res.text(), /not right/);
    assert.equal((await auth.gate(req('/admin/login', form(''))))!.status, 401);
    assert.equal((await auth.gate(req('/admin/login', form(PASSWORD + 'x'))))!.status, 401);
    assert.equal((await auth.gate(req('/admin/login', form(PASSWORD.slice(0, -1)))))!.status, 401);
  });

  await t.test('a script can sign in with JSON', async () => {
    const auth = newAuth();
    const ok = (await auth.gate(req('/admin/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: PASSWORD }) })))!;
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true });
    assert.ok(ok.headers.get('set-cookie'));
    const bad = (await auth.gate(req('/admin/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'not json' })))!;
    assert.equal(bad.status, 401);
  });

  await t.test('every sign-in gets its own unguessable session', async () => {
    const auth = newAuth();
    assert.notEqual(await signIn(auth), await signIn(auth));
  });

  await t.test('another server (or the same one restarted) does not know the session', async () => {
    const cookie = await signIn(newAuth());
    assert.equal((await newAuth().gate(req('/admin/api/state', { cookie })))!.status, 401);
  });
});

test('guessing the password', async (t) => {
  await t.test(`${MAX_FAILURES} wrong tries lock sign-in for ${LOCKOUT_SECONDS} seconds, even for the right password`, async () => {
    const auth = newAuth();
    for (let i = 0; i < MAX_FAILURES; i++) assert.equal((await auth.gate(req('/admin/login', form(`guess${i}`))))!.status, 401);
    const locked = (await auth.gate(req('/admin/login', form(PASSWORD))))!;
    assert.equal(locked.status, 429);
    assert.ok(Number(locked.headers.get('retry-after')) > 0);
    assert.equal(locked.headers.get('set-cookie'), null);

    clock += (LOCKOUT_SECONDS + 1) * 1000;
    assert.equal((await auth.gate(req('/admin/login', form(PASSWORD))))!.status, 303);
  });

  await t.test('a right password resets the count', async () => {
    const auth = newAuth();
    for (let i = 0; i < MAX_FAILURES - 1; i++) await auth.gate(req('/admin/login', form('x')));
    await signIn(auth);
    for (let i = 0; i < MAX_FAILURES - 1; i++) assert.equal((await auth.gate(req('/admin/login', form('x'))))!.status, 401);
    assert.equal((await auth.gate(req('/admin/login', form(PASSWORD))))!.status, 303);
  });
});

test('ending a session', async (t) => {
  await t.test('signing out ends it at once', async () => {
    const auth = newAuth();
    const cookie = await signIn(auth);
    assert.equal(await auth.gate(req('/admin/api/state', { cookie })), null);
    const out = (await auth.gate(req('/admin/logout', { cookie })))!;
    assert.equal(out.status, 303);
    assert.match(out.headers.get('set-cookie')!, /Max-Age=0/);
    assert.equal((await auth.gate(req('/admin/api/state', { cookie })))!.status, 401);
  });

  await t.test(`a session ends after ${SESSION_HOURS} hours`, async () => {
    const auth = newAuth();
    const cookie = await signIn(auth);
    clock += (SESSION_HOURS * 3600 - 1) * 1000;
    assert.equal(await auth.gate(req('/admin/api/state', { cookie })), null);
    clock += 2000;
    assert.equal((await auth.gate(req('/admin/api/state', { cookie })))!.status, 401);
  });
});
