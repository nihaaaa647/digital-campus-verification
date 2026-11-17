// The rules of scanner-sync, tested without a database: an in-memory SyncStore stands in for Postgres.
//   npm test            (from supabase/functions)
// pg_sync_store.test.ts runs the same handler against a real Postgres.

import assert from 'node:assert/strict';
import test from 'node:test';

import { MAX_SCANS_PER_REQUEST, handleScannerSync, hashToken, validateScan } from './scanner_sync.ts';
import type { GuardRecord, SaveResult, ScanRow, ScannerRecord, SyncDeps, SyncStore } from './scanner_sync.ts';

const NOW_S = 1793118000; // 2026-10-27T16:20:00Z
const TOKEN = 'dev-token';
const ID1 = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';

class MemoryStore implements SyncStore {
  scanners = new Map<string, ScannerRecord>([[hashToken(TOKEN), { id: 'SC-01', gate: 'Main', enabled: true }]]);
  scans = new Map<string, ScanRow>();
  touched: string[] = [];
  revocation: string | null = 'DR1.example';
  guards: GuardRecord[] = [{ id: 'G-03', name: 'Guard Three', pin_hash: 'pbkdf2$sha256$1$AA$AA' }];
  failWith: Error | null = null;
  /** Ids to name as stored even though the request did not carry them (a misbehaving store). */
  extraStored: string[] = [];
  /** Rows the "database" refuses, by id. */
  refuse = new Map<string, string>();
  calls: string[] = [];

  async findScannerByTokenHash(tokenHash: string): Promise<ScannerRecord | null> {
    this.calls.push('find');
    if (this.failWith) throw this.failWith;
    return this.scanners.get(tokenHash) ?? null;
  }

  async saveScans(_scanner: ScannerRecord, rows: ScanRow[]): Promise<SaveResult> {
    this.calls.push('save');
    const rejected = [];
    for (const row of rows) {
      const reason = this.refuse.get(row.scan_id);
      if (reason) {
        rejected.push({ scan_id: row.scan_id, reason });
        continue;
      }
      if (!this.scans.has(row.scan_id)) this.scans.set(row.scan_id, row);
    }
    return { stored: [...rows.filter((r) => !this.refuse.has(r.scan_id)).map((r) => r.scan_id), ...this.extraStored], rejected };
  }

  async touchScanner(scannerId: string): Promise<void> {
    this.calls.push('touch');
    this.touched.push(scannerId);
  }

  async latestRevocationList(): Promise<string | null> {
    return this.revocation;
  }

  async guardsFor(): Promise<GuardRecord[]> {
    return this.guards;
  }
}

function good(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    scan_id: ID1,
    scanned_at: '2026-10-27T16:19:04Z',
    student_id: 1042,
    roll_number: '25071A0001',
    type: 'OUT',
    gate: 'Main',
    guard_id: 'G-03',
    entry_method: 'scan',
    ...over,
  };
}

function request(body: unknown, headers: Record<string, string> = { Authorization: `Bearer ${TOKEN}` }, method = 'POST'): Request {
  const hasBody = method !== 'GET' && method !== 'HEAD';
  return new Request('https://example.test/functions/v1/scanner-sync', {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: hasBody ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  });
}

function setup(over: Partial<SyncDeps> = {}) {
  const store = new MemoryStore();
  const deps: SyncDeps = { store, keySet: null, now: () => NOW_S, ...over };
  const call = (req: Request) => handleScannerSync(req, deps);
  return { store, deps, call };
}

async function bodyOf(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

test('a token is stored as its lower-case hex SHA-256', () => {
  assert.equal(hashToken('dev-token'), 'c91cbbedf8c712e8e2b7517ddeca8fe4fde839ebd8339e0b2001363002b37712');
});

test('who is asking is checked first', async (t) => {
  await t.test('only POST is allowed', async () => {
    const { call, store } = setup();
    for (const method of ['GET', 'PUT', 'DELETE']) {
      assert.equal((await call(request({}, undefined, method))).status, 405, method);
    }
    assert.deepEqual(store.calls, []);
  });

  await t.test('no Authorization header is 401', async () => {
    const { call, store } = setup();
    const res = await call(request({ scans: [] }, {}));
    assert.equal(res.status, 401);
    assert.deepEqual(await bodyOf(res), { error: 'unauthorized' });
    assert.deepEqual(store.calls, [], 'the database is not even asked');
  });

  await t.test('another scheme, an empty token or a very short one is 401', async () => {
    const { call } = setup();
    for (const header of ['Basic abc123', 'Bearer ', 'Bearer abc', 'bearer', TOKEN]) {
      assert.equal((await call(request({ scans: [] }, { Authorization: header }))).status, 401, header);
    }
  });

  await t.test('a token nobody was given is 401', async () => {
    const { call, store } = setup();
    assert.equal((await call(request({ scans: [good()] }, { Authorization: 'Bearer some-other-token' }))).status, 401);
    assert.equal(store.scans.size, 0);
  });

  await t.test('a disabled scanner is 403 and stores nothing', async () => {
    const { call, store } = setup();
    store.scanners.set(hashToken(TOKEN), { id: 'SC-01', gate: 'Main', enabled: false });
    const res = await call(request({ scans: [good()] }));
    assert.equal(res.status, 403);
    assert.deepEqual(await bodyOf(res), { error: 'scanner_disabled' });
    assert.equal(store.scans.size, 0);
    assert.deepEqual(store.touched, []);
  });

  await t.test('the scheme name is not case sensitive', async () => {
    const { call } = setup();
    assert.equal((await call(request({ scans: [] }, { Authorization: `bearer ${TOKEN}` }))).status, 200);
  });
});

test('a malformed request is 400 or 413, and nothing is stored', async (t) => {
  await t.test('not JSON', async () => {
    const { call, store } = setup();
    const res = await call(request('{nope'));
    assert.equal(res.status, 400);
    assert.deepEqual(await bodyOf(res), { error: 'body_not_json' });
    assert.equal(store.scans.size, 0);
  });

  await t.test('JSON that is not an object with a scans list', async () => {
    const { call } = setup();
    for (const body of [[], 'text', 5, null, {}, { scans: 'x' }, { scans: {} }]) {
      assert.equal((await call(request(JSON.stringify(body)))).status, 400, JSON.stringify(body));
    }
  });

  await t.test('too many scans in one request', async () => {
    const { call, store } = setup();
    const scans = Array.from({ length: MAX_SCANS_PER_REQUEST + 1 }, (_, i) => good({ scan_id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}` }));
    const res = await call(request({ scans }));
    assert.equal(res.status, 413);
    assert.equal(store.scans.size, 0);
  });

  await t.test('exactly the maximum is fine', async () => {
    const { call, store } = setup();
    const scans = Array.from({ length: MAX_SCANS_PER_REQUEST }, (_, i) => good({ scan_id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}` }));
    const res = await call(request({ scans }));
    assert.equal(res.status, 200);
    assert.equal(store.scans.size, MAX_SCANS_PER_REQUEST);
  });

  await t.test('a huge body', async () => {
    const { call } = setup();
    assert.equal((await call(request(JSON.stringify({ scans: [], pad: 'x'.repeat(1_100_000) })))).status, 413);
  });
});

test('a good request', async (t) => {
  await t.test('stores the scans and names their ids', async () => {
    const { call, store } = setup();
    const res = await call(request({ scans: [good(), good({ scan_id: ID2, student_id: null, roll_number: '25071a0009', entry_method: 'manual' })], visitors: [] }));

    assert.equal(res.status, 200);
    const body = await bodyOf(res);
    assert.deepEqual(body.accepted_scan_ids, [ID1, ID2]);
    assert.deepEqual(body.rejected, []);
    assert.equal(body.server_time, NOW_S);
    assert.equal(store.scans.size, 2);
    assert.deepEqual(store.touched, ['SC-01']);
  });

  await t.test('normalises what it stores: UTC time, upper-case roll number', async () => {
    const { call, store } = setup();
    await call(request({ scans: [good({ scanned_at: '2026-10-27T21:49:04+05:30', roll_number: ' 25071a0001 ' })] }));
    const row = store.scans.get(ID1)!;
    assert.equal(row.scanned_at, '2026-10-27T16:19:04.000Z');
    assert.equal(row.roll_number, '25071A0001');
    assert.equal(row.student_id, 1042);
  });

  await t.test('with nothing to send it still answers: the scanner uses it to learn the time', async () => {
    const { call, store } = setup();
    const res = await call(request({ scans: [], visitors: [] }));
    assert.equal(res.status, 200);
    const body = await bodyOf(res);
    assert.deepEqual(body.accepted_scan_ids, []);
    assert.equal(body.server_time, NOW_S);
    assert.deepEqual(store.calls, ['find', 'touch'], 'no save call for an empty batch, but the sync is recorded');
  });

  await t.test('carries the key set, revocation list and guards', async () => {
    const keySet = { v: 1, current: 2, keys: [{ kv: 2, alg: 'ES256', pub: 'Arf2T6rVyC1iymOvnNc9yRz5PBxxtKf5ypfs0Outfdyw' }] };
    const { call } = setup({ keySet });
    const body = await bodyOf(await call(request({ scans: [] })));
    assert.deepEqual(body.keyset, keySet);
    assert.equal(body.revocation_list, 'DR1.example');
    assert.deepEqual(body.guards, [{ id: 'G-03', name: 'Guard Three', pin_hash: 'pbkdf2$sha256$1$AA$AA' }]);
  });

  await t.test('keyset and revocation list are null when there are none', async () => {
    const { call, store } = setup();
    store.revocation = null;
    const body = await bodyOf(await call(request({ scans: [] })));
    assert.equal(body.keyset, null);
    assert.equal(body.revocation_list, null);
  });

  await t.test('is not cached', async () => {
    const { call } = setup();
    assert.equal((await call(request({ scans: [] }))).headers.get('cache-control'), 'no-store');
  });

  await t.test('visitors are ignored for now', async () => {
    const { call } = setup();
    const res = await call(request({ scans: [], visitors: [{ visitor_name: 'x' }] }));
    assert.equal(res.status, 200);
  });
});

test('sending the same rows again', async (t) => {
  await t.test('names them again and does not store them twice', async () => {
    const { call, store } = setup();
    const first = await bodyOf(await call(request({ scans: [good()] })));
    const second = await bodyOf(await call(request({ scans: [good()] })));
    assert.deepEqual(first.accepted_scan_ids, [ID1]);
    assert.deepEqual(second.accepted_scan_ids, [ID1]);
    assert.equal(store.scans.size, 1);
  });

  await t.test('the same id twice in one request is named once', async () => {
    const { call } = setup();
    const body = await bodyOf(await call(request({ scans: [good(), good()] })));
    assert.deepEqual(body.accepted_scan_ids, [ID1]);
  });

  await t.test('an id comes back spelled the way the scanner spelled it', async () => {
    const { call, store } = setup();
    const upper = ID1.toUpperCase();
    const body = await bodyOf(await call(request({ scans: [good({ scan_id: upper })] })));
    assert.deepEqual(body.accepted_scan_ids, [upper], 'the scanner matches by its own spelling');
    assert.equal([...store.scans.keys()][0], ID1, 'stored in the canonical lower-case form');
  });

  await t.test('an id the request did not carry is never named', async () => {
    const { call, store } = setup();
    store.extraStored = [ID2, 'not-even-a-uuid'];
    const body = await bodyOf(await call(request({ scans: [good()] })));
    assert.deepEqual(body.accepted_scan_ids, [ID1]);
  });
});

test('a bad row is refused with its reason and does not hold up the others', async (t) => {
  const cases: Array<[string, Record<string, unknown>, string]> = [
    ['no scan id', { scan_id: undefined }, 'bad_scan_id'],
    ['scan id that is not a uuid', { scan_id: 'abc' }, 'bad_scan_id'],
    ['scan id of the wrong type', { scan_id: 12 }, 'bad_scan_id'],
    ['no time', { scanned_at: undefined }, 'bad_time'],
    ['time without a zone', { scanned_at: '2026-10-27T16:19:04' }, 'bad_time'],
    ['time that is not a time', { scanned_at: 'yesterday' }, 'bad_time'],
    ['a month that does not exist', { scanned_at: '2026-13-27T16:19:04Z' }, 'bad_time'],
    ['time before the system existed', { scanned_at: '2019-12-31T23:59:59Z' }, 'bad_time'],
    ['time more than a day ahead', { scanned_at: '2026-10-28T16:20:01Z' }, 'bad_time'],
    ['student id of the wrong type', { student_id: '1042' }, 'bad_student_id'],
    ['student id that is zero', { student_id: 0 }, 'bad_student_id'],
    ['student id that is a fraction', { student_id: 1.5 }, 'bad_student_id'],
    ['roll number too long', { student_id: null, roll_number: '12345678901234567' }, 'bad_roll_number'],
    ['roll number of the wrong type', { student_id: null, roll_number: 5 }, 'bad_roll_number'],
    ['neither a student id nor a roll number', { student_id: null, roll_number: null }, 'no_student'],
    ['neither, with an empty roll number', { student_id: undefined, roll_number: '' }, 'no_student'],
    ['unknown type', { type: 'IN' }, 'bad_type'],
    ['unknown entry method', { entry_method: 'telepathy' }, 'bad_entry_method'],
    ['no gate', { gate: '' }, 'bad_gate'],
    ['gate that is far too long', { gate: 'x'.repeat(65) }, 'bad_gate'],
    ['no guard', { guard_id: undefined }, 'bad_guard_id'],
    ['guard id too long', { guard_id: 'x'.repeat(33) }, 'bad_guard_id'],
  ];

  for (const [name, over, reason] of cases) {
    await t.test(name, async () => {
      const { call, store } = setup();
      const body = await bodyOf(await call(request({ scans: [good({ ...over }), good({ scan_id: ID2 })] })));

      assert.equal(store.scans.has(ID1), false, 'the bad row is not stored');
      assert.deepEqual(body.accepted_scan_ids, [ID2], 'the good row beside it still is');
      assert.equal((body.rejected as Array<{ reason: string }>)[0].reason, reason);
    });
  }

  await t.test('a row that is not even an object', async () => {
    const { call } = setup();
    const body = await bodyOf(await call(request({ scans: [5, null, 'x', [], good()] })));
    assert.deepEqual(body.accepted_scan_ids, [ID1]);
    assert.deepEqual(
      (body.rejected as Array<{ reason: string }>).map((r) => r.reason),
      ['not_an_object', 'not_an_object', 'not_an_object', 'not_an_object'],
    );
  });

  await t.test('exactly a day ahead is still allowed (clock skew)', () => {
    const r = validateScan(good({ scanned_at: '2026-10-28T16:20:00Z' }), NOW_S * 1000);
    assert.ok('row' in r);
  });

  await t.test('rows the database refuses are reported with its reason', async () => {
    const { call, store } = setup();
    store.refuse.set(ID1, 'unknown_guard');
    const body = await bodyOf(await call(request({ scans: [good(), good({ scan_id: ID2 })] })));
    assert.deepEqual(body.accepted_scan_ids, [ID2]);
    assert.deepEqual(body.rejected, [{ scan_id: ID1, reason: 'unknown_guard' }]);
  });
});

test('a failure inside is a plain 500 that says nothing about why', async () => {
  const { call, store } = setup();
  store.failWith = new Error('connection to db.internal:5432 refused; password=hunter2');
  const originalError = console.error;
  console.error = () => {};
  try {
    const res = await call(request({ scans: [good()] }));
    assert.equal(res.status, 500);
    const text = await res.text();
    assert.deepEqual(JSON.parse(text), { error: 'server_error' });
    assert.ok(!text.includes('hunter2') && !text.includes('db.internal'));
  } finally {
    console.error = originalError;
  }
});

test('the exact request the Dart scanner sends is understood (apps/scanner_app/test/sync_client_test.dart)', async () => {
  const { call, store } = setup();
  const res = await call(
    request({
      scans: [
        {
          scan_id: '00000001-0000-4000-8000-000000000000',
          scanned_at: '2026-10-27T16:47:04Z',
          student_id: 1042,
          roll_number: '25071A0001',
          type: 'OUT',
          gate: 'Main',
          guard_id: 'G-03',
          entry_method: 'scan',
        },
      ],
      visitors: [],
    }),
  );
  const body = await bodyOf(res);
  assert.equal(res.status, 200);
  assert.deepEqual(body.accepted_scan_ids, ['00000001-0000-4000-8000-000000000000']);
  assert.deepEqual(body.rejected, []);
  assert.equal(store.scans.size, 1);
});
