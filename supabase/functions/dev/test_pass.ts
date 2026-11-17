// A scan QR for a roster student, made by the local server itself with the PUBLIC test keys: the college key
// kv 2 signs the credential and test device key dev A signs the QR. It lets the scanner be tried with one phone
// (the QR is shown on the PC screen by /_dev/test-pass) and is not a real phone's pass. Never in a deployment.

import { PassType, buildScanQr, issueCredential, publicKeyOf } from '../_shared/credential.ts';
import type { Credential } from '../_shared/credential.ts';
import type { Db } from '../_shared/pg_sync_store.ts';
import type { CollegeSigner } from '../_shared/signer.ts';

export async function testPassQr(
  db: Db,
  signer: CollegeSigner,
  deviceKey: Uint8Array,
  roll: string,
  nowS = Math.floor(Date.now() / 1000),
): Promise<{ text: string; name: string } | null> {
  const rows = await db.query<{ id: number; roll_number: string; name: string; branch: string; year: number }>(
    "select id, roll_number, name, branch, year from public.students where upper(roll_number) = upper($1) and status = 'active'",
    [roll],
  );
  const s = rows[0];
  if (!s) return null;
  const credential: Credential = {
    v: 1,
    kv: signer.kv,
    sid: Number(s.id),
    roll: s.roll_number.toUpperCase(),
    name: s.name.normalize('NFC'),
    branch: s.branch,
    year: Number(s.year),
    pass: PassType.Student,
    photo: new Uint8Array(16),
    dpk: publicKeyOf(deviceKey),
    iat: nowS - 60,
    exp: nowS + 30 * 86400,
  };
  const issued = await issueCredential(credential, signer.sign);
  return { text: buildScanQr(issued, nowS, deviceKey), name: s.name };
}
