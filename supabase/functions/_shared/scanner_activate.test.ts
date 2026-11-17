// The rules of scanner-activate, tested without a database (an in-memory ActivateStore stands in).
//   npm test            (from supabase/functions)
// pg_activate.test.ts runs the same handler against a real Postgres.

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ACTIVATION_ALPHABET,
  generateActivationCode,
  handleScannerActivate,
  issueActivationCode,
  mintToken,
  normalizeActivationCode,
} from './scanner_activate.ts';
import type { ActivateDeps, ActivateStore, ActivatedScanner, PendingActivation } from './scanner_activate.ts';
import { hashToken } from './scanner_sync.ts';
import type { GuardRecord } from './scanner_sync.ts';

const NOW_S = 1793118000;
const CODE = 'K7QM-29XD';

class MemoryStore implements ActivateStore {
  /** code hash -> scanner */
  pending = new Map<string, PendingActivation>([[hashToken('K7QM29XD'), { id: 'SC-01', name: 'Main gate 1', gate: 'Main', enabled: true }]]);
  tokenHashes = new Map<string, string>();
  consumeCalls: Array<{ codeHash: string; tokenHash: string }> = [];
  seenArguments: string[] = [];
  failWith: Error | null = null;
  /** Make consumeActivation lose the race: someone else used the code first. */
  loseRace = false;
  revocation: string | null = 'DR1.example';
  guards: GuardRecord[] = [{ id: 'G-03', name: 'Guard Three', pin_hash: 'pbkdf2$sha256$1$AA$AA' }];

  async findPendingActivation(codeHash: string): Promise<PendingActivation | null> {
    this.seenArguments.push(codeHash);
    if (this.failWith) throw this.failWith;
    return this.pending.get(codeHash) ?? null;
  }

  async consumeActivation(codeHash: string, tokenHash: string): Promise<ActivatedScanner | null> {
    this.seenArguments.push(codeHash, tokenHash);
    this.consumeCalls.push({ codeHash, tokenHash });
    const p = this.pending.get(codeHash);
    if (!p || !p.enabled || this.loseRace) return null;
    this.pending.delete(codeHash);
    this.tokenHashes.set(p.id, tokenHash);
    return { id: p.id, name: p.name, gate: p.gate };
  }

  async latestRevocationList(): Promise<string | null> {
    return this.revocation;
  }

  async guardsFor(): Promise<GuardRecord[]> {
    return this.guards;
  }
}

function request(body: unknown, method = 'POST'): Request {
  const hasBody = method !== 'GET' && method !== 'HEAD';
  return new Request('https://example.test/functions/v1/scanner-activate', {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: hasBody ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  });
}

function setup(over: Partial<ActivateDeps> = {}) {
  const store = new MemoryStore();
  const deps: ActivateDeps = { store, keySet: null, now: () => NOW_S, ...over };
  return { store, deps, call: (req: Request) => handleScannerActivate(req, deps) };
}

async function bodyOf(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

test('activation codes', async (t) => {
  await t.test('are 8 characters in two groups of 4, from an alphabet without look-alikes', () => {
    for (let i = 0; i < 500; i++) {
      const code = generateActivationCode();
      assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    }
    for (const bad of ['0', '1', 'I', 'O']) assert.ok(!ACTIVATION_ALPHABET.includes(bad), bad);
    assert.equal(ACTIVATION_ALPHABET.length, 32, 'a power of two, so masking five bits picks each character equally often');
  });

  await t.test('come from the random source byte by byte', () => {
    assert.equal(generateActivationCode(() => Uint8Array.from([0, 1, 2, 3, 4, 5, 6, 31])), 'ABCD-EFG9');
    // only the low five bits of each byte count: 32 -> 0 (A), 33 -> 1 (B), 255 -> 31 (9)
    assert.equal(generateActivationCode(() => Uint8Array.from([32, 33, 255, 0, 64, 96, 128, 160])), 'AB9A-AAAA');
  });

  await t.test('do not repeat in practice', () => {
    assert.ok(new Set(Array.from({ length: 2000 }, () => generateActivationCode())).size > 1990);
  });

  await t.test('are read forgivingly: case, spaces and the hyphen do not matter', () => {
    for (const typed of ['K7QM-29XD', 'k7qm-29xd', 'K7QM29XD', ' k7qm 29xd ', 'K7QM_29XD'.replace('_', '-'), 'K7-QM-29-XD']) {
      assert.equal(normalizeActivationCode(typed), 'K7QM29XD', typed);
    }
  });

  await t.test('are refused when they cannot be a code', () => {
    for (const bad of ['', 'K7QM-29X', 'K7QM-29XDA', 'K7QM-29X0', 'K7QM-29XI', 'K7QM-29XO', 'K7QM-29X1', 'K7QM-29X!', null, undefined, 12345678, ['K7QM29XD']]) {
      assert.equal(normalizeActivationCode(bad as unknown), null, String(bad));
    }
  });
});

test('a scanner token is 43 URL-safe characters and different each time', () => {
  const tokens = Array.from({ length: 200 }, () => mintToken());
  for (const t of tokens) assert.match(t, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(new Set(tokens).size, 200);
});

test('issuing a code hands out the plain code and stores only its hash', async () => {
  const stored: Array<{ scannerId: string; codeHash: string; ttl: number }> = [];
  const issuer = {
    async setActivationCode(scannerId: string, codeHash: string, ttl: number) {
      stored.push({ scannerId, codeHash, ttl });
      return scannerId === 'SC-01';
    },
  };

  const code = await issueActivationCode(issuer, 'SC-01');
  assert.match(code as string, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
  assert.equal(stored[0].codeHash, hashToken(normalizeActivationCode(code) as string));
  assert.ok(!JSON.stringify(stored).includes((code as string).replace('-', '')), 'the plain code is not given to storage');
  assert.equal(stored[0].ttl, 15);
  assert.equal(await issueActivationCode(issuer, 'SC-NOPE'), null);
  assert.equal((await issueActivationCode(issuer, 'SC-01', 5))!.length, 9);
  assert.equal(stored[2].ttl, 5);
});

test('the request is checked', async (t) => {
  await t.test('only POST', async () => {
    const { call } = setup();
    for (const m of ['GET', 'PUT', 'DELETE']) assert.equal((await call(request({}, m))).status, 405, m);
  });

  await t.test('not JSON, or not an object with a code', async () => {
    const { call, store } = setup();
    assert.equal((await call(request('{nope'))).status, 400);
    for (const body of [[], 'text', 5, null, {}, { token: 'x' }]) {
      assert.equal((await call(request(JSON.stringify(body)))).status, 400, JSON.stringify(body));
    }
    assert.deepEqual(store.seenArguments, [], 'the database is not touched');
  });

  await t.test('a huge body', async () => {
    const { call } = setup();
    assert.equal((await call(request(JSON.stringify({ code: CODE, pad: 'x'.repeat(5000) })))).status, 413);
  });
});

test('a wrong code teaches nothing', async (t) => {
  const answer = async (code: unknown, tweak?: (s: MemoryStore) => void) => {
    const { call, store } = setup();
    tweak?.(store);
    const res = await call(request({ code }));
    return { status: res.status, body: await bodyOf(res), store };
  };

  await t.test('unknown, malformed, wrong type and already used all give the same 404', async () => {
    const unknown = await answer('ZZZZ-ZZZZ');
    const malformed = await answer('abc');
    const wrongType = await answer(12345678);
    const used = await answer(CODE, (s) => s.pending.clear());

    for (const r of [unknown, malformed, wrongType, used]) {
      assert.equal(r.status, 404);
      assert.deepEqual(r.body, { error: 'invalid_or_expired_code' });
    }
  });

  await t.test('a malformed code is not even looked up', async () => {
    const { store } = await answer('abc');
    assert.deepEqual(store.seenArguments, []);
  });

  await t.test('no token is made for a code that is not valid', async () => {
    const { store } = await answer('ZZZZ-ZZZZ');
    assert.equal(store.consumeCalls.length, 0);
    assert.equal(store.tokenHashes.size, 0);
  });
});

test('a disabled scanner is refused and its code is left alone', async () => {
  const { call, store } = setup();
  store.pending.set(hashToken('K7QM29XD'), { id: 'SC-01', name: 'Main gate 1', gate: 'Main', enabled: false });

  const res = await call(request({ code: CODE }));

  assert.equal(res.status, 403);
  assert.deepEqual(await bodyOf(res), { error: 'scanner_disabled' });
  assert.equal(store.consumeCalls.length, 0);
  assert.equal(store.pending.size, 1, 'not used up: the admin can enable the scanner and the same code works');
});

test('a good code', async (t) => {
  await t.test('returns the scanner, its token, and what it needs to start', async () => {
    const keySet = { v: 1, current: 2, keys: [{ kv: 2, alg: 'ES256', pub: 'Arf2T6rVyC1iymOvnNc9yRz5PBxxtKf5ypfs0Outfdyw' }] };
    const { call } = setup({ keySet, newToken: () => 'T'.repeat(43) });

    const res = await call(request({ code: CODE }));
    const body = await bodyOf(res);

    assert.equal(res.status, 200);
    assert.deepEqual(body, {
      scanner_id: 'SC-01',
      name: 'Main gate 1',
      gate: 'Main',
      token: 'T'.repeat(43),
      keyset: keySet,
      revocation_list: 'DR1.example',
      guards: [{ id: 'G-03', name: 'Guard Three', pin_hash: 'pbkdf2$sha256$1$AA$AA' }],
      server_time: NOW_S,
    });
    assert.equal(res.headers.get('cache-control'), 'no-store');
  });

  await t.test('stores only hashes: of the code, and of the token it hands out', async () => {
    const { call, store } = setup();
    const body = await bodyOf(await call(request({ code: 'k7qm 29xd' })));
    const token = body.token as string;

    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    assert.deepEqual(store.consumeCalls, [{ codeHash: hashToken('K7QM29XD'), tokenHash: hashToken(token) }]);
    for (const seen of store.seenArguments) {
      assert.ok(!seen.includes('K7QM29XD') && !seen.includes(token), 'neither the code nor the token reaches storage in plain text');
    }
    assert.equal(store.tokenHashes.get('SC-01'), hashToken(token));
  });

  await t.test('works once: the same code again is a 404', async () => {
    const { call } = setup();
    assert.equal((await call(request({ code: CODE }))).status, 200);
    const again = await call(request({ code: CODE }));
    assert.equal(again.status, 404);
    assert.deepEqual(await bodyOf(again), { error: 'invalid_or_expired_code' });
  });

  await t.test('two scanners get different tokens', async () => {
    const { call, store } = setup();
    store.pending.set(hashToken('ABCD2345'), { id: 'SC-02', name: 'Gate 2', gate: 'North', enabled: true });
    const a = (await bodyOf(await call(request({ code: CODE })))).token;
    const b = (await bodyOf(await call(request({ code: 'ABCD-2345' })))).token;
    assert.notEqual(a, b);
  });

  await t.test('losing a race for the code is a plain 404 and gives out no token', async () => {
    const { call, store } = setup();
    store.loseRace = true;
    const res = await call(request({ code: CODE }));
    assert.equal(res.status, 404);
    assert.ok(!JSON.stringify(await bodyOf(res)).includes('token'));
  });

  await t.test('keyset and revocation list are null when there are none', async () => {
    const { call, store } = setup();
    store.revocation = null;
    const body = await bodyOf(await call(request({ code: CODE })));
    assert.equal(body.keyset, null);
    assert.equal(body.revocation_list, null);
  });
});

test('a failure inside is a plain 500 that says nothing about why', async () => {
  const { call, store } = setup();
  store.failWith = new Error('connection to db.internal:5432 refused; password=hunter2');
  const originalError = console.error;
  console.error = () => {};
  try {
    const res = await call(request({ code: CODE }));
    const text = await res.text();
    assert.equal(res.status, 500);
    assert.deepEqual(JSON.parse(text), { error: 'server_error' });
    assert.ok(!text.includes('hunter2'));
  } finally {
    console.error = originalError;
  }
});
