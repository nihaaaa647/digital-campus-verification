// scanner-activate on a real Postgres (PGlite) with the project's migration and seed: the code is used
// up atomically, only hashes are stored, and the token it hands out is the one scanner-sync accepts.
//   npm test            (from supabase/functions)

import assert from 'node:assert/strict';
import test from 'node:test';
import type { PGlite } from '@electric-sql/pglite';

import { createLocalDatabase, pgliteDb } from '../dev/local_db.ts';
import { PgSyncStore } from './pg_sync_store.ts';
import { handleScannerActivate, issueActivationCode, normalizeActivationCode } from './scanner_activate.ts';
import { handleScannerSync, hashToken } from './scanner_sync.ts';

const NOW_S = 1793118000;
const keySet = { v: 1, current: 2, keys: [{ kv: 2, alg: 'ES256', pub: 'Arf2T6rVyC1iymOvnNc9yRz5PBxxtKf5ypfs0Outfdyw' }] };

let pg: PGlite;
let store: PgSyncStore;

test.before(async () => {
  pg = await createLocalDatabase();
  store = new PgSyncStore(pgliteDb(pg));
});
test.after(async () => {
  await pg.close();
});
test.beforeEach(async () => {
  // SC-NEW back to "never activated", SC-DEV as seeded
  await pg.exec(`
    truncate public.scans;
    update public.scanners set token_hash = null, activation_code_hash = null, activation_expires_at = null, enabled = true where id = 'SC-NEW';
    update public.scanners set token_hash = '${hashToken('dev-token')}', enabled = true where id = 'SC-DEV';`);
});

const activate = (code: unknown) =>
  handleScannerActivate(
    new Request('https://example.test/functions/v1/scanner-activate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code }) }),
    { store, keySet, now: () => NOW_S },
  );

const sync = (token: string, scans: unknown[] = []) =>
  handleScannerSync(
    new Request('https://example.test/functions/v1/scanner-sync', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ scans }),
    }),
    { store, keySet: null, now: () => NOW_S },
  );

async function scannerRow(id: string) {
  return (await pg.query<{ token_hash: string | null; activation_code_hash: string | null; activation_expires_at: Date | string | null }>(
    'select token_hash, activation_code_hash, activation_expires_at from public.scanners where id = $1',
    [id],
  )).rows[0];
}

test('issuing a code', async (t) => {
  await t.test('stores its hash and an expiry about 15 minutes ahead, and never the code itself', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    const row = await scannerRow('SC-NEW');

    assert.equal(row.activation_code_hash, hashToken(normalizeActivationCode(code) as string));
    const minutes = (new Date(row.activation_expires_at as string).getTime() - Date.now()) / 60_000;
    assert.ok(minutes > 14 && minutes <= 15.1, `expires in ${minutes.toFixed(1)} minutes`);
    const everything = JSON.stringify((await pg.query('select * from public.scanners')).rows);
    assert.ok(!everything.includes(code.replace('-', '')) && !everything.includes(code));
  });

  await t.test('for a scanner that does not exist gives nothing', async () => {
    assert.equal(await issueActivationCode(store, 'SC-NOPE'), null);
  });

  await t.test('a second code replaces the first', async () => {
    const first = (await issueActivationCode(store, 'SC-NEW'))!;
    const second = (await issueActivationCode(store, 'SC-NEW'))!;
    assert.equal((await activate(first)).status, 404);
    assert.equal((await activate(second)).status, 200);
  });
});

test('activating', async (t) => {
  await t.test('swaps the code for a token, clears the code, and stores only the token hash', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    const res = await activate(code);
    const body = (await res.json()) as Record<string, unknown>;

    assert.equal(res.status, 200);
    assert.equal(body.scanner_id, 'SC-NEW');
    assert.equal(body.name, 'New scanner (not activated)');
    assert.equal(body.gate, 'North gate');
    assert.deepEqual(body.keyset, keySet);
    assert.deepEqual((body.guards as Array<{ id: string }>).map((g) => g.id), ['G-DEV']);
    assert.equal(body.server_time, NOW_S);

    const row = await scannerRow('SC-NEW');
    assert.equal(row.token_hash, hashToken(body.token as string));
    assert.equal(row.activation_code_hash, null, 'the code is used up');
    assert.equal(row.activation_expires_at, null);
    assert.ok(!JSON.stringify(row).includes(body.token as string), 'the token itself is not stored');
  });

  await t.test('the same code a second time is a 404', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    assert.equal((await activate(code)).status, 200);
    assert.equal((await activate(code)).status, 404);
  });

  await t.test('two requests with the same code at the same moment: exactly one gets a token', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    const results = await Promise.all(Array.from({ length: 6 }, () => activate(code)));
    const statuses = results.map((r) => r.status).sort();

    assert.deepEqual(statuses, [200, 404, 404, 404, 404, 404]);
    const winner = (await Promise.all(results.map(async (r) => (r.status === 200 ? ((await r.json()) as { token: string }).token : null)))).find(Boolean)!;
    assert.equal((await scannerRow('SC-NEW')).token_hash, hashToken(winner), 'the stored token is the winner\'s');
  });

  await t.test('an expired code is a 404 and does not touch the scanner', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    await pg.exec("update public.scanners set activation_expires_at = now() - interval '1 second' where id = 'SC-NEW'");
    assert.equal((await activate(code)).status, 404);
    assert.equal((await scannerRow('SC-NEW')).token_hash, null);
  });

  await t.test('a code that was never issued is a 404, the same answer as an expired one', async () => {
    const real = (await issueActivationCode(store, 'SC-NEW'))!;
    await pg.exec("update public.scanners set activation_expires_at = now() - interval '1 second' where id = 'SC-NEW'");
    const expired = await activate(real);
    const unknown = await activate('ZZZZ-ZZZZ');
    assert.equal(expired.status, unknown.status);
    assert.deepEqual(await expired.json(), await unknown.json());
  });

  await t.test('a disabled scanner is refused with 403, and its code survives for when it is enabled', async () => {
    const code = (await issueActivationCode(store, 'SC-NEW'))!;
    await pg.exec("update public.scanners set enabled = false where id = 'SC-NEW'");

    assert.equal((await activate(code)).status, 403);
    assert.equal((await scannerRow('SC-NEW')).token_hash, null);
    assert.ok((await scannerRow('SC-NEW')).activation_code_hash, 'not used up');

    await pg.exec("update public.scanners set enabled = true where id = 'SC-NEW'");
    assert.equal((await activate(code)).status, 200);
  });
});

test('the token it hands out is the one scanner-sync accepts', async (t) => {
  const scan = {
    scan_id: '00000000-0000-4000-8000-000000000001',
    scanned_at: '2026-10-27T16:19:04Z',
    student_id: 1,
    roll_number: '25071A0001',
    type: 'OUT',
    gate: 'North gate',
    guard_id: 'G-DEV',
    entry_method: 'scan',
  };

  await t.test('before activation the scanner has no token at all', async () => {
    assert.equal((await sync('anything-at-all')).status, 401);
  });

  await t.test('after activation: sync works, and the scans are the new scanner\'s', async () => {
    const token = ((await (await activate((await issueActivationCode(store, 'SC-NEW'))!)).json()) as { token: string }).token;

    const res = await sync(token, [scan]);
    assert.equal(res.status, 200);
    assert.deepEqual(((await res.json()) as { accepted_scan_ids: string[] }).accepted_scan_ids, [scan.scan_id]);
    assert.equal((await pg.query<{ scanner_id: string }>('select scanner_id from public.scans')).rows[0].scanner_id, 'SC-NEW');
  });

  await t.test('activating again replaces the token: the old one stops working at once', async () => {
    const first = ((await (await activate((await issueActivationCode(store, 'SC-NEW'))!)).json()) as { token: string }).token;
    assert.equal((await sync(first)).status, 200);

    const second = ((await (await activate((await issueActivationCode(store, 'SC-NEW'))!)).json()) as { token: string }).token;

    assert.notEqual(first, second);
    assert.equal((await sync(first)).status, 401, 'the old token is dead');
    assert.equal((await sync(second)).status, 200);
  });

  await t.test('another scanner\'s token is not affected', async () => {
    await activate((await issueActivationCode(store, 'SC-NEW'))!);
    assert.equal((await sync('dev-token')).status, 200);
  });

  await t.test('a scanner that is disabled after activating is refused by sync with 403', async () => {
    const token = ((await (await activate((await issueActivationCode(store, 'SC-NEW'))!)).json()) as { token: string }).token;
    await pg.exec("update public.scanners set enabled = false where id = 'SC-NEW'");
    assert.equal((await sync(token)).status, 403);
  });
});
