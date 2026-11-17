// The SQL behind scanner-sync, run on a real Postgres (PGlite) with the project's own migration and seed.
//   npm test            (from supabase/functions)

import assert from 'node:assert/strict';
import test from 'node:test';
import type { PGlite } from '@electric-sql/pglite';

import { createLocalDatabase, pgliteDb } from '../dev/local_db.ts';
import { PgSyncStore } from './pg_sync_store.ts';
import { handleScannerSync, hashToken } from './scanner_sync.ts';
import type { ScanRow, ScannerRecord } from './scanner_sync.ts';

const NOW_S = 1793118000;
const ID = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

function row(n: number, over: Partial<ScanRow> = {}): ScanRow {
  return {
    scan_id: ID(n),
    scanned_at: '2026-10-27T16:19:04.000Z',
    student_id: null,
    roll_number: '25071A0001',
    type: 'OUT',
    gate: 'Main',
    guard_id: 'G-DEV',
    entry_method: 'scan',
    ...over,
  };
}

let pg: PGlite;
let store: PgSyncStore;
let scanner: ScannerRecord;
let sampleId: number;

test.before(async () => {
  pg = await createLocalDatabase();
  store = new PgSyncStore(pgliteDb(pg));
  scanner = (await store.findScannerByTokenHash(hashToken('dev-token')))!;
  sampleId = Number((await pg.query<{ id: string }>("select id::text as id from public.students where roll_number = '25071A0001'")).rows[0].id);
});
test.after(async () => {
  await pg.close();
});
test.beforeEach(async () => {
  await pg.exec('truncate public.scans; delete from public.revocation_lists;');
  await pg.exec("update public.scanners set enabled = true, last_sync_at = null where id = 'SC-DEV'; delete from public.guards where id <> 'G-DEV';");
});

async function scanCount(): Promise<number> {
  return Number((await pg.query<{ n: string }>('select count(*)::text as n from public.scans')).rows[0].n);
}

test('the migration and the seed ran on a real Postgres', async () => {
  const tables = (await pg.query<{ table_name: string }>("select table_name from information_schema.tables where table_schema = 'public'")).rows.map((r) => r.table_name);
  for (const expected of ['students', 'scanners', 'guards', 'scans', 'revocation_lists', 'settings', 'outpass_export']) {
    assert.ok(tables.includes(expected), `missing table ${expected}`);
  }
  assert.equal(scanner.id, 'SC-DEV');
});

test('finding a scanner by its token hash', async (t) => {
  await t.test('the dev scanner is found', () => {
    assert.deepEqual(scanner, { id: 'SC-DEV', gate: 'Main', enabled: true });
  });
  await t.test('an unknown hash is not', async () => {
    assert.equal(await store.findScannerByTokenHash(hashToken('nope')), null);
    assert.equal(await store.findScannerByTokenHash(''), null);
  });
  await t.test('a scanner with no token yet is never found by an empty hash', async () => {
    await pg.exec("insert into public.scanners (id, name) values ('SC-NEW', 'Not activated yet') on conflict do nothing");
    assert.equal(await store.findScannerByTokenHash(''), null);
  });
  await t.test('a disabled scanner is found, marked disabled', async () => {
    await pg.exec("update public.scanners set enabled = false where id = 'SC-DEV'");
    assert.equal((await store.findScannerByTokenHash(hashToken('dev-token')))!.enabled, false);
  });
});

test('saving scans', async (t) => {
  await t.test('stores a scan with everything the export needs', async () => {
    const result = await store.saveScans(scanner, [row(1, { student_id: sampleId })]);

    assert.deepEqual(result.stored, [ID(1)]);
    assert.deepEqual(result.rejected, []);
    const saved = (await pg.query<Record<string, unknown>>('select scan_id::text, scanned_at, student_id::text, roll_number, type, gate, scanner_id, guard_id, entry_method, synced_at from public.scans')).rows[0];
    assert.equal(saved.scan_id, ID(1));
    assert.equal(saved.student_id, String(sampleId));
    assert.equal(saved.roll_number, '25071A0001');
    assert.equal(saved.scanner_id, 'SC-DEV', 'the scanner comes from the token, not from the request');
    assert.equal(saved.guard_id, 'G-DEV');
    assert.equal(new Date(saved.scanned_at as string | Date).toISOString(), '2026-10-27T16:19:04.000Z');
    assert.ok(saved.synced_at, 'synced_at is set by the server');
  });

  await t.test('sending the same row twice stores one row and names it both times', async () => {
    const first = await store.saveScans(scanner, [row(1)]);
    const second = await store.saveScans(scanner, [row(1)]);

    assert.deepEqual(first.stored, [ID(1)]);
    assert.deepEqual(second.stored, [ID(1)]);
    assert.equal(await scanCount(), 1);
  });

  await t.test('a repeat does not change the row that was stored first', async () => {
    await store.saveScans(scanner, [row(1, { gate: 'Main' })]);
    await store.saveScans(scanner, [row(1, { gate: 'Different' })]);
    assert.equal((await pg.query<{ gate: string }>('select gate from public.scans')).rows[0].gate, 'Main');
  });

  await t.test('the same id twice in one call stores one row', async () => {
    const result = await store.saveScans(scanner, [row(1), row(1)]);
    assert.deepEqual(result.stored, [ID(1)]);
    assert.equal(await scanCount(), 1);
  });

  await t.test('a batch is stored together', async () => {
    const rows = Array.from({ length: 200 }, (_, i) => row(i + 1));
    const result = await store.saveScans(scanner, rows);
    assert.equal(result.stored.length, 200);
    assert.equal(await scanCount(), 200);
  });
});

test('who a scan belongs to', async (t) => {
  await t.test('a manual entry with only a roll number is linked to the student by roll number', async () => {
    await store.saveScans(scanner, [row(1, { student_id: null, roll_number: '25071A0001', entry_method: 'manual' })]);
    const saved = (await pg.query<{ student_id: string }>('select student_id::text from public.scans')).rows[0];
    assert.equal(saved.student_id, String(sampleId));
  });

  await t.test('a student id that does not exist falls back to the roll number', async () => {
    await store.saveScans(scanner, [row(1, { student_id: 999999, roll_number: '25071A0001' })]);
    assert.equal((await pg.query<{ student_id: string }>('select student_id::text from public.scans')).rows[0].student_id, String(sampleId));
  });

  await t.test('someone who is not on the roster is still an exit that happened: kept by roll number', async () => {
    const result = await store.saveScans(scanner, [row(1, { student_id: 999999, roll_number: 'GHOST-001' })]);
    assert.deepEqual(result.stored, [ID(1)]);
    const saved = (await pg.query<{ student_id: string | null; roll_number: string }>('select student_id::text, roll_number from public.scans')).rows[0];
    assert.equal(saved.student_id, null);
    assert.equal(saved.roll_number, 'GHOST-001');
  });

  await t.test('an unknown student id and no roll number cannot be kept', async () => {
    const result = await store.saveScans(scanner, [row(1, { student_id: 999999, roll_number: null }), row(2, { student_id: sampleId, roll_number: null })]);
    assert.deepEqual(result.rejected, [{ scan_id: ID(1), reason: 'unknown_student' }]);
    assert.deepEqual(result.stored, [ID(2)]);
  });

  await t.test('the outpass export shows the student the scan was resolved to', async () => {
    await store.saveScans(scanner, [row(1, { student_id: null, roll_number: '25071A0001', entry_method: 'manual' })]);
    const exported = (await pg.query<{ roll_number: string; name: string; class: string; entry_method: string; scanner_id: string }>('select roll_number, name, class, entry_method, scanner_id from public.outpass_export')).rows[0];
    assert.deepEqual(exported, { roll_number: '25071A0001', name: 'Sample Student', class: 'II', entry_method: 'manual', scanner_id: 'SC-DEV' });
  });
});

test('guards', async (t) => {
  await t.test('a scan by a guard the server does not know is refused, and the rest of the batch is stored', async () => {
    const result = await store.saveScans(scanner, [row(1, { guard_id: 'G-UNKNOWN' }), row(2)]);
    assert.deepEqual(result.rejected, [{ scan_id: ID(1), reason: 'unknown_guard' }]);
    assert.deepEqual(result.stored, [ID(2)]);
    assert.equal(await scanCount(), 1);
  });

  await t.test('a refused row is not stored even if it is sent again', async () => {
    await store.saveScans(scanner, [row(1, { guard_id: 'G-UNKNOWN' })]);
    const again = await store.saveScans(scanner, [row(1, { guard_id: 'G-UNKNOWN' })]);
    assert.deepEqual(again.stored, []);
  });

  await t.test('once the guard exists the same row is accepted', async () => {
    await store.saveScans(scanner, [row(1, { guard_id: 'G-NEW' })]);
    await pg.exec("insert into public.guards (id, name, pin_hash) values ('G-NEW', 'New guard', 'x')");
    const result = await store.saveScans(scanner, [row(1, { guard_id: 'G-NEW' })]);
    assert.deepEqual(result.stored, [ID(1)]);
  });

  await t.test('a guard who has since been disabled still has their old scans accepted', async () => {
    await pg.exec("insert into public.guards (id, name, pin_hash, enabled) values ('G-OLD', 'Left the college', 'x', false)");
    const result = await store.saveScans(scanner, [row(1, { guard_id: 'G-OLD' })]);
    assert.deepEqual(result.stored, [ID(1)]);
  });

  await t.test('guardsFor lists enabled guards for this scanner or for any scanner, by id', async () => {
    await pg.exec(`
      insert into public.scanners (id, name) values ('SC-OTHER', 'Other gate');
      insert into public.guards (id, name, scanner_id, pin_hash, enabled) values
        ('G-A', 'Any scanner', null, 'pa', true),
        ('G-B', 'This scanner', 'SC-DEV', 'pb', true),
        ('G-C', 'Other scanner only', 'SC-OTHER', 'pc', true),
        ('G-D', 'Disabled', null, 'pd', false)
      on conflict do nothing;`);
    const guards = await store.guardsFor('SC-DEV');
    assert.deepEqual(guards.map((g) => g.id), ['G-A', 'G-B', 'G-DEV']);
    assert.deepEqual(guards.find((g) => g.id === 'G-B'), { id: 'G-B', name: 'This scanner', pin_hash: 'pb' });
  });
});

test('a database error stores nothing at all', async () => {
  // a type the table refuses (the handler never lets it through; this checks the transaction)
  await assert.rejects(store.saveScans(scanner, [row(1), row(2, { type: 'BOGUS' as never })]));
  assert.equal(await scanCount(), 0, 'row 1 was rolled back with row 2');
});

test('recording a sync, and what is published', async (t) => {
  await t.test('touchScanner sets last_sync_at', async () => {
    assert.equal((await pg.query<{ last_sync_at: unknown }>("select last_sync_at from public.scanners where id = 'SC-DEV'")).rows[0].last_sync_at, null);
    await store.touchScanner('SC-DEV');
    const at = (await pg.query<{ last_sync_at: Date | string }>("select last_sync_at from public.scanners where id = 'SC-DEV'")).rows[0].last_sync_at;
    assert.ok(Math.abs(new Date(at).getTime() - Date.now()) < 60_000);
  });

  await t.test('there is no revocation list until one is published, then the newest is served', async () => {
    assert.equal(await store.latestRevocationList(), null);
    await pg.exec("insert into public.revocation_lists (key_version, encoded) values (2, 'DR1.first'), (2, 'DR1.second')");
    assert.equal(await store.latestRevocationList(), 'DR1.second');
  });
});

test('the whole path: handler + store + database', async (t) => {
  const call = (body: unknown, token = 'dev-token') =>
    handleScannerSync(
      new Request('https://example.test/functions/v1/scanner-sync', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      }),
      { store, keySet: null, now: () => NOW_S },
    );
  const scan = (n: number, over: Record<string, unknown> = {}) => ({
    scan_id: ID(n),
    scanned_at: '2026-10-27T16:19:04Z',
    student_id: sampleId,
    roll_number: '25071A0001',
    type: 'OUT',
    gate: 'Main',
    guard_id: 'G-DEV',
    entry_method: 'scan',
    ...over,
  });

  await t.test('a scanner syncs its exits and the server holds them', async () => {
    const res = await call({ scans: [scan(1), scan(2), scan(3)], visitors: [] });
    const body = (await res.json()) as { accepted_scan_ids: string[]; server_time: number; guards: Array<{ id: string }> };

    assert.equal(res.status, 200);
    assert.deepEqual(body.accepted_scan_ids, [ID(1), ID(2), ID(3)]);
    assert.equal(body.server_time, NOW_S);
    assert.deepEqual(body.guards.map((g) => g.id), ['G-DEV']);
    assert.equal(await scanCount(), 3);
    assert.ok((await pg.query('select 1 from public.scanners where id = $1 and last_sync_at is not null', ['SC-DEV'])).rows.length === 1);
  });

  await t.test('the reply to the first attempt is lost, the scanner sends everything again, and nothing is doubled', async () => {
    await call({ scans: [scan(1), scan(2)] }); // stored; the reply "never arrives"
    const retry = (await (await call({ scans: [scan(1), scan(2), scan(3)] })).json()) as { accepted_scan_ids: string[] };

    assert.deepEqual(retry.accepted_scan_ids, [ID(1), ID(2), ID(3)]);
    assert.equal(await scanCount(), 3);
  });

  await t.test('a refused row is reported and the good ones are kept', async () => {
    const body = (await (await call({ scans: [scan(1, { guard_id: 'G-NOPE' }), scan(2)] })).json()) as {
      accepted_scan_ids: string[];
      rejected: Array<{ scan_id: string; reason: string }>;
    };
    assert.deepEqual(body.accepted_scan_ids, [ID(2)]);
    assert.deepEqual(body.rejected, [{ scan_id: ID(1), reason: 'unknown_guard' }]);
  });

  await t.test('a wrong token gets nothing and stores nothing', async () => {
    const res = await call({ scans: [scan(1)] }, 'wrong-token-value');
    assert.equal(res.status, 401);
    assert.equal(await scanCount(), 0);
  });

  await t.test('a disabled scanner gets 403 and stores nothing', async () => {
    await pg.exec("update public.scanners set enabled = false where id = 'SC-DEV'");
    const res = await call({ scans: [scan(1)] });
    assert.equal(res.status, 403);
    assert.equal(await scanCount(), 0);
  });

  await t.test('a published revocation list reaches the scanner', async () => {
    await pg.exec("insert into public.revocation_lists (key_version, encoded) values (2, 'DR1.published')");
    const body = (await (await call({ scans: [] })).json()) as { revocation_list: string };
    assert.equal(body.revocation_list, 'DR1.published');
  });
});
