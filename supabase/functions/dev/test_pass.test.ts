import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { hexToBytes } from '@noble/hashes/utils';

import { parseKeySet, verifyScan } from '../_shared/credential.ts';
import type { KeySetDocument } from '../_shared/credential.ts';
import { devCollegeSigner } from './dev_signer.ts';
import { createLocalDatabase, pgliteDb } from './local_db.ts';
import { testPassQr } from './test_pass.ts';

const vectors = JSON.parse(readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8')) as {
  keyset_json: KeySetDocument;
  keys: { devices: Array<{ name: string; private_hex: string }> };
};
const deviceKey = hexToBytes(vectors.keys.devices.find((k) => k.name === 'dev_a')!.private_hex);

test('the QR shown on the PC screen is accepted by a scanner holding the key set the server hands out', async () => {
  const pg = await createLocalDatabase();
  try {
    const db = pgliteDb(pg);
    const now = 1_793_000_000;
    const pass = await testPassQr(db, devCollegeSigner(), deviceKey, '25071a0003', now);
    assert.ok(pass);
    assert.equal(pass.name, 'Ravi Kumar');

    const keys = parseKeySet(vectors.keyset_json);
    const outcome = verifyScan(pass.text, { now, keys });
    assert.equal(outcome.ok, true);
    if (outcome.ok) {
      assert.equal(outcome.credential.name, 'Ravi Kumar');
      assert.equal(outcome.credential.roll, '25071A0003');
      assert.equal(outcome.credential.sid, 3, 'the scan resolves to the student id on the roster');
    }
    assert.equal(verifyScan(pass.text, { now: now + 60, keys }).ok, false, 'and goes stale like any other QR');
  } finally {
    await pg.close();
  }
});

test('a student who is not on the roster, or is paused, gets no pass', async () => {
  const pg = await createLocalDatabase();
  try {
    const db = pgliteDb(pg);
    assert.equal(await testPassQr(db, devCollegeSigner(), deviceKey, 'NOPE'), null);
    await pg.exec("update public.students set status = 'paused' where roll_number = '25071A0003'");
    assert.equal(await testPassQr(db, devCollegeSigner(), deviceKey, '25071A0003'), null);
  } finally {
    await pg.close();
  }
});
