// The production database path: the Edge Function reaches Postgres through postgres.js, not through
// PGlite's own client. This runs the same store through postgres.js, over a real socket to a real
// Postgres engine (PGlite's socket server), so the adapter (postgresJsDb) is tested too: array
// parameters, uuid/timestamptz casts, bigint columns and transactions.
//   npm test            (from supabase/functions)

import assert from 'node:assert/strict';
import test from 'node:test';
import type { AddressInfo } from 'node:net';
import type { PGlite } from '@electric-sql/pglite';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import postgres from 'postgres';

import { createLocalDatabase } from '../dev/local_db.ts';
import { PgSyncStore, postgresJsDb } from './pg_sync_store.ts';
import type { PostgresJsLike } from './pg_sync_store.ts';
import { handleScannerSync, hashToken } from './scanner_sync.ts';
import type { ScanRow, ScannerRecord } from './scanner_sync.ts';

const ID = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

let pg: PGlite;
let server: PGLiteSocketServer;
let sql: ReturnType<typeof postgres>;
let store: PgSyncStore;
let scanner: ScannerRecord;

test.before(async () => {
  pg = await createLocalDatabase();
  server = new PGLiteSocketServer({ db: pg, port: 0, host: '127.0.0.1' });
  await server.start();
  const port = (server as unknown as { server: { address(): AddressInfo } }).server.address().port;
  // One connection: PGlite serves one at a time. The function itself uses a small pool.
  sql = postgres({ host: '127.0.0.1', port, username: 'postgres', password: 'postgres', database: 'postgres', max: 1, prepare: false, ssl: false, onnotice: () => {} });
  store = new PgSyncStore(postgresJsDb(sql as unknown as PostgresJsLike));
  scanner = (await store.findScannerByTokenHash(hashToken('dev-token')))!;
});
test.after(async () => {
  await sql.end({ timeout: 2 });
  await server.stop();
  await pg.close();
});
test.beforeEach(async () => {
  await pg.exec('truncate public.scans;');
});

function row(n: number, over: Partial<ScanRow> = {}): ScanRow {
  return { scan_id: ID(n), scanned_at: '2026-10-27T16:19:04.000Z', student_id: null, roll_number: '25071A0001', type: 'OUT', gate: 'Main', guard_id: 'G-DEV', entry_method: 'scan', ...over };
}

async function count(): Promise<number> {
  return Number((await pg.query<{ n: string }>('select count(*)::text as n from public.scans')).rows[0].n);
}

test('postgres.js can reach the database and find the scanner', () => {
  assert.deepEqual(scanner, { id: 'SC-DEV', gate: 'Main', enabled: true });
});

test('saving, repeating and resolving work through postgres.js exactly as through PGlite', async (t) => {
  await t.test('a batch is stored with array parameters, casts and the right column types', async () => {
    const result = await store.saveScans(scanner, [row(1, { student_id: 999999 }), row(2, { student_id: null, roll_number: '25071A0001', entry_method: 'manual' })]);
    assert.deepEqual([...result.stored].sort(), [ID(1), ID(2)]);
    const saved = (await pg.query<{ scan_id: string; student_id: string; scanned_at: Date; entry_method: string }>('select scan_id::text, student_id::text, scanned_at, entry_method from public.scans order by scan_id')).rows;
    assert.equal(saved.length, 2);
    assert.ok(saved.every((r) => r.student_id !== null), 'both resolved to the student by roll number');
    assert.equal(new Date(saved[0].scanned_at).toISOString(), '2026-10-27T16:19:04.000Z');
  });

  await t.test('a repeat names the same ids and stores no copies', async () => {
    await store.saveScans(scanner, [row(1), row(2)]);
    const again = await store.saveScans(scanner, [row(1), row(2), row(3)]);
    assert.deepEqual([...again.stored].sort(), [ID(1), ID(2), ID(3)]);
    assert.equal(await count(), 3);
  });

  await t.test('rows for an unknown guard are refused, the rest stored', async () => {
    const result = await store.saveScans(scanner, [row(1, { guard_id: 'G-NOPE' }), row(2)]);
    assert.deepEqual(result.rejected, [{ scan_id: ID(1), reason: 'unknown_guard' }]);
    assert.deepEqual(result.stored, [ID(2)]);
  });

  await t.test('an empty list of ids is fine (no array of zero length trouble)', async () => {
    const result = await store.saveScans(scanner, [row(1, { guard_id: 'G-NOPE' })]);
    assert.deepEqual(result.stored, []);
    assert.equal(await count(), 0);
  });

  await t.test('a database error rolls the whole transaction back', async () => {
    await assert.rejects(store.saveScans(scanner, [row(1), row(2, { type: 'BOGUS' as never })]));
    assert.equal(await count(), 0);
  });

  await t.test('a batch of 500 (the largest the function accepts) goes through', async () => {
    const rows = Array.from({ length: 500 }, (_, i) => row(i + 1));
    const result = await store.saveScans(scanner, rows);
    assert.equal(result.stored.length, 500);
    assert.equal(await count(), 500);
  });
});

test('touching, revocation list and guards through postgres.js', async () => {
  await store.touchScanner('SC-DEV');
  assert.ok((await pg.query("select 1 from public.scanners where id = 'SC-DEV' and last_sync_at is not null")).rows.length === 1);
  assert.equal(await store.latestRevocationList(), null);
  assert.deepEqual((await store.guardsFor('SC-DEV')).map((g) => g.id), ['G-DEV']);
});

test('the handler end to end over postgres.js', async () => {
  const res = await handleScannerSync(
    new Request('https://example.test/functions/v1/scanner-sync', {
      method: 'POST',
      headers: { Authorization: 'Bearer dev-token', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        scans: [{ scan_id: ID(1), scanned_at: '2026-10-27T16:19:04Z', student_id: 1, roll_number: '25071A0001', type: 'OUT', gate: 'Main', guard_id: 'G-DEV', entry_method: 'scan' }],
      }),
    }),
    { store, keySet: null, now: () => 1793118000 },
  );
  const body = (await res.json()) as { accepted_scan_ids: string[]; guards: unknown[] };
  assert.equal(res.status, 200);
  assert.deepEqual(body.accepted_scan_ids, [ID(1)]);
  assert.equal(body.guards.length, 1);
  assert.equal(await count(), 1);
});
