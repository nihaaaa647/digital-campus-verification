// The prototype admin page's API, on a real Postgres (PGlite).
//   npm test            (from supabase/functions)

import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import type { PGlite } from '@electric-sql/pglite';

import { handleAdmin } from '../dev/admin.ts';
import { createLocalDatabase, pgliteDb } from '../dev/local_db.ts';
import { PgSyncStore } from './pg_sync_store.ts';
import { handleScannerActivate } from './scanner_activate.ts';
import { handleScannerSync } from './scanner_sync.ts';

let pg: PGlite;
let deps: { db: ReturnType<typeof pgliteDb>; issuer: PgSyncStore };

test.before(async () => {
  pg = await createLocalDatabase();
  deps = { db: pgliteDb(pg), issuer: new PgSyncStore(pgliteDb(pg)) };
});
test.after(async () => {
  await pg.close();
});
test.beforeEach(async () => {
  await pg.exec(`
    truncate public.scans; delete from public.enrolments; delete from public.dev_photos;
    delete from public.students where id > 5; delete from public.scanners where id not in ('SC-DEV', 'SC-NEW');
    update public.scanners set token_hash = null, activation_code_hash = null, activation_expires_at = null where id = 'SC-NEW';`);
});

const call = (path: string, method = 'GET', body?: unknown) =>
  handleAdmin(new Request(`http://localhost${path}`, { method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) }), deps);

const j = async (res: Response | null) => (await res!.json()) as Record<string, any>;

async function enrolStudent(studentId: number, status = 'pending') {
  await pg.exec(`insert into auth.users (id, email) values (gen_random_uuid(), 'u${studentId}@x.test') on conflict do nothing`);
  await pg.exec(`insert into public.enrolments (student_id, auth_user_id, phone, status, photo_path, photo_hash) select ${studentId}, id, '9876543210', '${status}', 'p', '\\x00112233445566778899aabbccddeeff' from auth.users where email = 'u${studentId}@x.test'`);
}

test('what is not the admin page is left alone', async () => {
  assert.equal(await call('/functions/v1/scanner-sync'), null);
  assert.equal(await call('/anything/else'), null);
});

test('the page itself', async () => {
  const res = (await call('/admin'))!;
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type')!, /text\/html/);
  const html = await res.text();
  assert.match(html, /Campus ID/);
  assert.ok(html.includes('const esc ='), 'every value from the database goes through an escaping helper');
  assert.ok(!html.includes('Sample Student'), 'the page holds no data; it fetches it');
});

test('state', async (t) => {
  await t.test('lists the roster, scanners and counts, and nothing needs a password the server does not check here', async () => {
    const state = await j(await call('/admin/api/state'));
    assert.ok(state.students.length >= 5);
    assert.deepEqual(state.scanners.map((s: any) => s.id).sort(), ['SC-DEV', 'SC-NEW']);
    assert.equal(state.scanners.find((s: any) => s.id === 'SC-DEV').activated, true);
    assert.equal(state.scanners.find((s: any) => s.id === 'SC-NEW').activated, false);
    assert.deepEqual(state.counts, { exits: 0, today: 0 });
    assert.deepEqual(state.enrolments, []);
  });

  await t.test('shows enrolments waiting for review first, with their flags', async () => {
    await enrolStudent(1, 'approved');
    await enrolStudent(2, 'pending');
    await pg.exec("update public.enrolments set status = 'flagged', flags = '{duplicate}' where student_id = 3");
    await enrolStudent(3, 'flagged');
    const state = await j(await call('/admin/api/state'));
    assert.deepEqual(state.enrolments.map((e: any) => e.status), ['flagged', 'pending', 'approved']);
    assert.equal(state.enrolments[1].name, 'Anita Rao');
  });
});

test('adding students', async (t) => {
  const student = (over: Record<string, unknown> = {}) => ({ roll_number: '26071a0010', name: ' New Student ', branch: 'IT', year: 2, college_email: 'New.Student@College.test', ...over });

  await t.test('adds one, tidying the roll number and email', async () => {
    assert.equal((await call('/admin/api/students', 'POST', student()))!.status, 200);
    const row = (await pg.query<{ roll_number: string; name: string; college_email: string }>("select roll_number, name, college_email from public.students where roll_number = '26071A0010'")).rows[0];
    assert.deepEqual(row, { roll_number: '26071A0010', name: 'New Student', college_email: 'new.student@college.test' });
  });

  await t.test('a year given as text is fine; rubbish is refused with a plain message', async () => {
    assert.equal((await call('/admin/api/students', 'POST', student({ year: '3', roll_number: 'R3', college_email: 'r3@college.test' })))!.status, 200);
    for (const bad of [{ year: 0 }, { year: 7 }, { year: 'x' }, { roll_number: '' }, { name: '' }, { branch: 'x'.repeat(13) }, { college_email: 'nope' }, { roll_number: 'x'.repeat(17) }]) {
      const res = await call('/admin/api/students', 'POST', student({ roll_number: 'R9', college_email: 'r9@college.test', ...bad }));
      assert.equal(res!.status, 400, JSON.stringify(bad));
      assert.match((await j(res)).error, /Check every field/);
    }
  });

  await t.test('a roll number or email that is already there is a 409', async () => {
    await call('/admin/api/students', 'POST', student());
    const dupRoll = await call('/admin/api/students', 'POST', student({ college_email: 'other@college.test' }));
    const dupEmail = await call('/admin/api/students', 'POST', student({ roll_number: 'DIFFERENT' }));
    for (const res of [dupRoll, dupEmail]) {
      assert.equal(res!.status, 409);
      assert.match((await j(res)).error, /already on the roster/);
    }
  });

  await t.test('a body that is not JSON is refused, not a crash', async () => {
    const res = await handleAdmin(new Request('http://localhost/admin/api/students', { method: 'POST', body: 'nope' }), deps);
    assert.equal(res!.status, 400);
  });
});

test('reviewing enrolments', async (t) => {
  await t.test('approve and reject change the status', async () => {
    await enrolStudent(1);
    const id = (await pg.query<{ id: string }>('select id::text as id from public.enrolments')).rows[0].id;

    assert.deepEqual(await j(await call(`/admin/api/enrolments/${id}/approve`, 'POST')), { ok: true, status: 'approved' });
    assert.equal((await pg.query<{ status: string }>('select status from public.enrolments')).rows[0].status, 'approved');
    assert.deepEqual(await j(await call(`/admin/api/enrolments/${id}/reject`, 'POST')), { ok: true, status: 'rejected' });
    assert.equal((await pg.query<{ status: string }>('select status from public.enrolments')).rows[0].status, 'rejected');
    assert.ok((await pg.query<{ reviewed_at: unknown }>('select reviewed_at from public.enrolments')).rows[0].reviewed_at);
  });

  await t.test('an enrolment that does not exist is a 404', async () => {
    assert.equal((await call('/admin/api/enrolments/9999/approve', 'POST'))!.status, 404);
  });

  await t.test('only POST changes anything', async () => {
    await enrolStudent(1);
    assert.equal((await call('/admin/api/enrolments/1/approve', 'GET'))!.status, 404);
  });
});

test('photos', async (t) => {
  await t.test('are served with their own content type', async () => {
    await pg.query("insert into public.dev_photos (student_id, content_type, bytes) values (1, 'image/jpeg', $1::bytea)", [new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3])]);
    const res = (await call('/admin/api/photo/1'))!;
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'image/jpeg');
    assert.deepEqual([...new Uint8Array(await res.arrayBuffer())], [0xff, 0xd8, 0xff, 1, 2, 3]);
  });

  await t.test('a student with none is a 404', async () => {
    assert.equal((await call('/admin/api/photo/2'))!.status, 404);
  });
});

test('scanners and activation codes', async (t) => {
  await t.test('adds a scanner and refuses a duplicate or a bad id', async () => {
    assert.equal((await call('/admin/api/scanners', 'POST', { id: 'sc-02', name: 'Back gate 1', gate: 'Back gate' }))!.status, 200);
    assert.equal((await pg.query('select 1 from public.scanners where id = $1', ['SC-02'])).rows.length, 1);
    assert.equal((await call('/admin/api/scanners', 'POST', { id: 'SC-02', name: 'x', gate: 'y' }))!.status, 409);
    for (const bad of [{ id: '' }, { id: 'has space' }, { name: '' }, { gate: '' }]) {
      assert.equal((await call('/admin/api/scanners', 'POST', { id: 'SC-03', name: 'n', gate: 'g', ...bad }))!.status, 400, JSON.stringify(bad));
    }
  });

  await t.test('a code made here activates that scanner, and the token it gets can sync', async () => {
    const { code, valid_minutes } = await j(await call('/admin/api/scanners/SC-NEW/code', 'POST'));
    assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    assert.equal(valid_minutes, 15);

    const store = new PgSyncStore(pgliteDb(pg));
    const activated = await j(await handleScannerActivate(new Request('http://localhost/x', { method: 'POST', body: JSON.stringify({ code }) }), { store, keySet: null }));
    assert.equal(activated.scanner_id, 'SC-NEW');
    const sync = await handleScannerSync(
      new Request('http://localhost/x', { method: 'POST', headers: { Authorization: `Bearer ${activated.token}` }, body: JSON.stringify({ scans: [] }) }),
      { store, keySet: null },
    );
    assert.equal(sync.status, 200);
    assert.equal((await j(await call('/admin/api/state'))).scanners.find((s: any) => s.id === 'SC-NEW').activated, true);
  });

  await t.test('a scanner that does not exist gets no code', async () => {
    assert.equal((await call('/admin/api/scanners/SC-NOPE/code', 'POST'))!.status, 404);
  });
});

test('the exits table and its CSV', async (t) => {
  async function addExit(id: string, studentId: number | null, roll: string | null, method = 'scan') {
    await pg.query(
      `insert into public.scans (scan_id, scanned_at, student_id, roll_number, type, gate, scanner_id, guard_id, entry_method)
       values ($1::uuid, '2026-10-27T16:19:04Z', $2::bigint, $3, 'OUT', 'Main', 'SC-DEV', 'G-DEV', $4)`,
      [id, studentId, roll, method],
    );
  }

  await t.test('shows who left, by the student the scan resolved to, in Indian time', async () => {
    await addExit('00000000-0000-4000-8000-000000000001', 2, 'ANITA');
    await addExit('00000000-0000-4000-8000-000000000002', null, '25071A0003', 'manual');
    const state = await j(await call('/admin/api/state'));

    assert.deepEqual(state.counts.exits, 2);
    const anita = state.scans.find((s: any) => s.name === 'Anita Rao');
    assert.equal(anita.timestamp, '2026-10-27 21:49:04', '16:19 UTC is 21:49 in India');
    assert.equal(anita.class, 'III');
    assert.equal(state.scans.find((s: any) => s.roll_number === '25071A0003').name, 'Ravi Kumar', 'a manual entry is matched by its roll number');
  });

  await t.test('downloads as a CSV that opens correctly in Excel: header, quoting, accents', async () => {
    await pg.exec("update public.students set name = 'Śrāvya, \"Ñandini\"' where roll_number = 'ADM26-00317'");
    await addExit('00000000-0000-4000-8000-000000000003', 5, null);
    const res = (await call('/admin/api/exits.csv'))!;
    // Response.text() drops a leading byte order mark, so look at the bytes.
    const bytes = new Uint8Array(await res.arrayBuffer());
    const text = new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes);

    assert.equal(res.status, 200);
    assert.deepEqual([...bytes.slice(0, 3)], [0xef, 0xbb, 0xbf]);
    assert.match(res.headers.get('content-type')!, /text\/csv/);
    assert.match(res.headers.get('content-disposition')!, /attachment; filename="outpass-export\.csv"/);
    assert.ok(text.startsWith('﻿Timestamp,Roll number,Name,Class,Branch,Phone,Type,Gate,Scanner,Guard,Entry method\r\n'), 'a byte order mark so Excel reads the accents');
    assert.ok(text.includes('"Śrāvya, ""Ñandini"""'), 'commas and quotes in a name are quoted');
    assert.equal(text.trim().split('\r\n').length, 2);
  });

  await t.test('an empty table still downloads, with just the header', async () => {
    const text = await (await call('/admin/api/exits.csv'))!.text();
    assert.equal(text.trim().split('\r\n').length, 1);
  });
});

test('anything else under /admin/api is a 404', async () => {
  assert.equal((await call('/admin/api/nothing'))!.status, 404);
});

test('searching the exits', async (t) => {
  async function addExit(id: string, at: string, studentId: number, gate = 'Main') {
    await pg.query(
      `insert into public.scans (scan_id, scanned_at, student_id, roll_number, type, gate, scanner_id, guard_id, entry_method)
       values ($1::uuid, $2::timestamptz, $3::bigint, null, 'OUT', $4, 'SC-DEV', 'G-DEV', 'scan')`,
      [id, at, studentId, gate],
    );
  }
  const ids = ['00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a3'];

  test.beforeEach(async () => {
    await addExit(ids[0], '2026-10-27T16:19:04Z', 2); // Anita Rao, 27 Oct 21:49 in India
    await addExit(ids[1], '2026-10-28T09:00:00Z', 3, 'North gate'); // Ravi Kumar, 28 Oct 14:30
    await addExit(ids[2], '2026-10-28T20:00:00Z', 2); // Anita Rao, 29 Oct 01:30 in India: a new day there
  });

  const list = async (query = '') => j(await call(`/admin/api/exits${query}`));

  await t.test('lists everything newest first, with the count', async () => {
    const r = await list();
    assert.equal(r.total, 3);
    assert.deepEqual(r.rows.map((x: any) => x.timestamp), ['2026-10-29 01:30:00', '2026-10-28 14:30:00', '2026-10-27 21:49:04']);
  });

  await t.test('finds a student by part of the name or roll number, ignoring case', async () => {
    assert.equal((await list('?q=anita')).total, 2);
    assert.equal((await list('?q=25071A0003')).rows[0].name, 'Ravi Kumar');
    assert.equal((await list('?q=0003')).total, 1);
    assert.equal((await list('?q=north')).total, 1, 'or by gate');
    assert.equal((await list('?q=nobody')).total, 0);
  });

  await t.test('days are India days, and both ends are included', async () => {
    assert.equal((await list('?from=2026-10-28')).total, 2);
    assert.equal((await list('?to=2026-10-27')).total, 1);
    assert.equal((await list('?from=2026-10-28&to=2026-10-28')).total, 1, 'the exit at 01:30 on the 29th in India is not on the 28th');
    assert.equal((await list('?from=2026-10-27&to=2026-10-29')).total, 3);
    assert.equal((await list('?from=2026-10-30')).total, 0);
  });

  await t.test('search and days together', async () => {
    assert.equal((await list('?q=anita&from=2026-10-28')).total, 1);
  });

  await t.test('rubbish in the query is ignored, and % and _ are not wildcards', async () => {
    assert.equal((await list('?from=yesterday&to=2026-13-45')).total, 3);
    assert.equal((await list('?q=%25')).total, 0, 'a literal %, which matches nobody');
    assert.equal((await list('?q=_')).total, 0);
    assert.equal((await list("?q=x'%20or%201=1--")).total, 0, 'quotes are only text');
  });

  await t.test('the CSV has exactly what the search shows, and is named for the days', async () => {
    const res = (await call('/admin/api/exits.csv?q=anita&from=2026-10-28'))!;
    const text = new TextDecoder().decode(new Uint8Array(await res.arrayBuffer()));
    assert.match(res.headers.get('content-disposition')!, /outpass-2026-10-28-to-now\.csv/);
    const lines = text.replace('﻿', '').trim().split('\r\n');
    assert.equal(lines.length, 2, 'the header and one row');
    assert.match(lines[1], /^2026-10-29 01:30:00,25071A0002,Anita Rao,/);

    const all = (await call('/admin/api/exits.csv'))!;
    assert.match(all.headers.get('content-disposition')!, /outpass-export\.csv/);
    assert.equal((await all.text()).trim().split('\r\n').length, 4);
  });

  await t.test('shows at most 500 rows but says how many there are', async () => {
    await pg.exec(`insert into public.scans (scan_id, scanned_at, student_id, type, gate, scanner_id, guard_id, entry_method)
                   select gen_random_uuid(), '2026-10-20T10:00:00Z'::timestamptz + (g || ' seconds')::interval, 2, 'OUT', 'Main', 'SC-DEV', 'G-DEV', 'scan' from generate_series(1, 600) g`);
    const r = await list();
    assert.equal(r.total, 603);
    assert.equal(r.shown, 500);
    const csv = (await call('/admin/api/exits.csv'))!;
    assert.equal((await csv.text()).trim().split('\r\n').length, 604, 'the CSV is not cut off');
  });
});

test('the admin page', async (t) => {
  await t.test('its script is valid JavaScript, and it has the search form, the sign-out link and no data', async () => {
    const html = await (await call('/admin'))!.text();
    const script = /<script>([\s\S]*)<\/script>/.exec(html)![1];
    assert.doesNotThrow(() => new vm.Script(script));
    assert.ok(html.includes('href="/admin/logout"'));
    assert.ok(html.includes('f-exits'));
    assert.ok(!html.includes('Anita'));
  });
});
