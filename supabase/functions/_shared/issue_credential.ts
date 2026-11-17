// POST /functions/v1/issue-credential (PRD S5, S9, S11): the student app asks for its pass.
//
//   Authorization: Bearer <access_token>
//   { "device_public_key": "<base64url, 33 bytes, compressed P-256, from the phone's Keystore>" }
//
//   200 { "signed_credential": "DK1....", "server_time": 1793000000, "key_version": 2 }
//   401 not logged in   403 not approved yet / student paused or revoked   422 bad key or profile
//
// The rules are docs/credential-spec.md section 11:
//  - only for an approved enrolment and an active student;
//  - the pass is bound to the key the phone made, which never leaves the phone's Keystore;
//  - `iat` is now, but never at or before a time this student's credentials were revoked, so that a new
//    phone's pass is not caught by the revocation of the old one;
//  - `exp` is 180 days on (the spec allows up to 200);
//  - a second phone replaces the first: the first phone's device is marked revoked in the same step.
//
// The signing key is a `CollegeSigner` (signer.ts): a function secret now, a cloud KMS later.

import { p256 } from '@noble/curves/p256';
import { bytesToHex } from '@noble/hashes/utils';
import { PassType, fromBase64Url, issueCredential } from './credential.ts';
import type { Credential } from './credential.ts';
import type { EnrolmentStatus } from './enrolment.ts';
import type { CollegeSigner } from './signer.ts';
import { authenticate } from './student_auth.ts';
import type { AuthStore } from './student_auth.ts';

export const CREDENTIAL_LIFETIME_DAYS = 180;
const MAX_NAME_BYTES = 64;
const MAX_BRANCH_BYTES = 12;
const MAX_ROLL_BYTES = 16;

export interface IssueState {
  student: { id: number; roll_number: string; name: string; branch: string; year: number; status: string };
  /** The student's enrolment, or null if they never enrolled. */
  enrolmentStatus: EnrolmentStatus | null;
  /** The 16-byte photo hash from the enrolment, or null. */
  photoHash: Uint8Array | null;
}

export interface IssuedAt {
  /** What goes into the pass, and into the devices table. */
  iat: number;
  exp: number;
}

export interface IssueStore extends Pick<AuthStore, 'findSession'> {
  loadIssueState(studentId: number): Promise<IssueState | null>;
  /**
   * In one transaction: mark the student's other active devices revoked, tell [build] the latest time any of
   * their devices was revoked (unix seconds, null if never), let it produce the pass, and record this device
   * as active with the times [build] returns. If [build] throws, nothing is changed.
   */
  swapDevice<T>(
    studentId: number,
    devicePublicKey: Uint8Array,
    keyVersion: number,
    build: (latestRevokedAtS: number | null) => Promise<IssuedAt & { value: T }>,
  ): Promise<T>;
}

export interface IssueDeps {
  store: IssueStore;
  signer: CollegeSigner;
  now?: () => number;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

const byteLength = (s: string) => new TextEncoder().encode(s).length;

/** The phone's public key if it is 33 bytes, compressed, and a real point on P-256; otherwise null. */
export function readDeviceKey(input: unknown): Uint8Array | null {
  if (typeof input !== 'string') return null;
  const key = fromBase64Url(input);
  if (key === null || key.length !== 33 || (key[0] !== 0x02 && key[0] !== 0x03)) return null;
  try {
    p256.ProjectivePoint.fromHex(bytesToHex(key)).assertValidity();
    return key;
  } catch {
    return null;
  }
}

export async function handleIssueCredential(req: Request, deps: IssueDeps): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const now = deps.now ?? (() => Math.floor(Date.now() / 1000));
  try {
    const caller = await authenticate(req, deps.store);
    if (caller === null) return json({ error: 'unauthorized' }, 401);

    const text = await req.text();
    let body: unknown;
    try {
      body = text.length > 5000 ? null : JSON.parse(text);
    } catch {
      body = null;
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return json({ error: 'body_not_json' }, 400);
    const deviceKey = readDeviceKey((body as { device_public_key?: unknown }).device_public_key);
    if (deviceKey === null) return json({ error: 'bad_device_key' }, 422);

    const state = await deps.store.loadIssueState(caller.studentId);
    if (state === null) return json({ error: 'unauthorized' }, 401);
    if (state.enrolmentStatus !== 'approved') return json({ error: 'not_approved', status: state.enrolmentStatus ?? 'none' }, 403);
    if (state.student.status !== 'active') return json({ error: 'student_not_active' }, 403);

    // The pass has fixed field sizes; a roster entry that does not fit is the admin's to fix, not the phone's.
    const s = state.student;
    const name = s.name.normalize('NFC');
    const roll = s.roll_number.toUpperCase();
    if (byteLength(name) > MAX_NAME_BYTES || byteLength(s.branch) > MAX_BRANCH_BYTES || byteLength(roll) > MAX_ROLL_BYTES || s.year < 1 || s.year > 6) {
      return json({ error: 'profile_invalid' }, 422);
    }

    const nowS = now();
    const signedCredential = await deps.store.swapDevice(s.id, deviceKey, deps.signer.kv, async (latestRevokedAtS) => {
      // Never at or before a revocation, or the new pass would be caught by it (spec section 7).
      const iat = Math.max(nowS, (latestRevokedAtS ?? 0) + 1);
      const credential: Credential = {
        v: 1,
        kv: deps.signer.kv,
        sid: s.id,
        roll,
        name,
        branch: s.branch,
        year: s.year,
        pass: PassType.Student,
        photo: state.photoHash ?? new Uint8Array(16),
        dpk: deviceKey,
        iat,
        exp: iat + CREDENTIAL_LIFETIME_DAYS * 86400,
      };
      const issued = await issueCredential(credential, deps.signer.sign);
      return { iat, exp: credential.exp, value: issued.signedText };
    });

    return json({ signed_credential: signedCredential, server_time: nowS, key_version: deps.signer.kv });
  } catch (error) {
    console.error('issue-credential failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}
