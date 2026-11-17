// Registration after login (PRD S2, S3, A3): the student gives a phone number and a photo. There is no
// approval step per student: signing in already proved they own `<roll number>@<college domain>`
// (student_auth.ts), so a new enrolment is approved at once and the pass can be issued (issue_credential.ts).
// A student the roster did not list also gives name, branch and year here, once (the app reads them off the
// ID card, which stays on the phone).
//
//   POST /functions/v1/enrol               Authorization: Bearer <access_token>
//     { "phone": "+91 98765 43210", "photo_base64": "<JPEG or PNG, up to 1.5 MB>",
//       "name": "...", "branch": "...", "year": 2 }     (name, branch, year only while the profile is incomplete)
//     200 { "status": "approved", "flags": [] }
//     400 bad_phone, bad_photo or bad_profile     409 already approved
//
//   GET  /functions/v1/enrolment-status    Authorization: Bearer <access_token>
//     200 { "status": "none" | "pending" | "flagged" | "approved" | "rejected", "flags": [], "student": { ..., "profile_complete": true } }
//
// Photos stay on the server (the PRD keeps ID-card images on the phone; only the photo goes up). The 16-byte
// hash of the photo is what goes into the pass (docs/credential-spec.md section 4).
//
// An admin can still reject an enrolment (a wrong photo). The student then sends a new one, which waits for an
// admin ('pending') instead of being approved on the spot, so a rejection cannot be undone by sending it again.
// A photo another student already enrolled with is flagged ('duplicate') for the admin to look at, not blocked.
// An approved student may not change the photo themselves.

import { sha256 } from '@noble/hashes/sha256';
import { authenticate } from './student_auth.ts';
import type { AuthStore, Caller, RosterStudent } from './student_auth.ts';

export const MAX_PHOTO_BYTES = 1_500_000;
export const MIN_PHOTO_BYTES = 1_000;

export type EnrolmentStatus = 'pending' | 'flagged' | 'approved' | 'rejected';

export interface EnrolmentRecord {
  id: number;
  status: EnrolmentStatus;
  flags: string[];
}

export interface Photo {
  contentType: 'image/jpeg' | 'image/png';
  bytes: Uint8Array;
  /** The first 16 bytes of the SHA-256 of [bytes]. */
  hash: Uint8Array;
}

export interface EnrolStore {
  findStudentById(id: number): Promise<RosterStudent | null>;
  getEnrolment(studentId: number): Promise<EnrolmentRecord | null>;
  /** Sets name, branch and year on a student whose profile is incomplete, and marks it complete. */
  completeProfile(studentId: number, profile: StudentProfile): Promise<void>;
  /**
   * Saves (or replaces) the student's enrolment with the photo and the given status, and sets the flags:
   * 'duplicate' when another student already enrolled with this very photo.
   */
  saveEnrolment(caller: Caller, phone: string, photo: Photo, status: EnrolmentStatus): Promise<EnrolmentRecord>;
}

export interface StudentProfile {
  name: string;
  branch: string;
  year: number;
}

export interface EnrolDeps {
  store: EnrolStore & Pick<AuthStore, 'findSession'>;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

/** `+91 98765-43210` -> `+919876543210`. Null if it cannot be a phone number. */
export function normalizePhone(input: unknown): string | null {
  if (typeof input !== 'string') return null;
  const p = input.replace(/[\s()-]/g, '');
  return /^\+?\d{10,15}$/.test(p) ? p : null;
}

/** Reads the photo the student sent. Null if it is not base64, the wrong size, or not a JPEG or PNG. */
export function readPhoto(input: unknown): Photo | null {
  if (typeof input !== 'string' || input.length === 0) return null;
  let bytes: Uint8Array;
  try {
    const bin = atob(input.replace(/^data:[^,]*,/, '').replace(/\s/g, ''));
    bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  if (bytes.length < MIN_PHOTO_BYTES || bytes.length > MAX_PHOTO_BYTES) return null;
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpeg && !png) return null;
  return { contentType: jpeg ? 'image/jpeg' : 'image/png', bytes, hash: sha256(bytes).slice(0, 16) };
}

const byteLength = (s: string) => new TextEncoder().encode(s).length;

/** Name, branch and year from the request, or null if any is missing or does not fit on a pass. */
export function readProfile(body: Record<string, unknown>): StudentProfile | null {
  const text = (v: unknown) => (typeof v === 'string' ? v.normalize('NFC').replace(/\s+/g, ' ').trim() : '');
  const name = text(body.name);
  const branch = text(body.branch).toUpperCase();
  const year = typeof body.year === 'string' && /^\d$/.test(body.year) ? Number(body.year) : body.year;
  if (name === '' || byteLength(name) > 64 || /\p{Cc}/u.test(name)) return null;
  if (branch === '' || byteLength(branch) > 12 || /\p{Cc}/u.test(branch)) return null;
  if (typeof year !== 'number' || !Number.isInteger(year) || year < 1 || year > 6) return null;
  return { name, branch, year };
}

export async function handleEnrol(req: Request, deps: EnrolDeps): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const caller = await authenticate(req, deps.store);
    if (caller === null) return json({ error: 'unauthorized' }, 401);

    const text = await req.text();
    // Roughly twice the largest photo, so a photo that is merely too big is told so (bad_photo) and only a
    // request that is absurdly big is cut off.
    if (text.length > MAX_PHOTO_BYTES * 2 + 10_000) return json({ error: 'body_too_large' }, 413);
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return json({ error: 'body_not_json' }, 400);
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return json({ error: 'body_not_json' }, 400);

    const phone = normalizePhone((body as { phone?: unknown }).phone);
    if (phone === null) return json({ error: 'bad_phone' }, 400);
    const photo = readPhoto((body as { photo_base64?: unknown }).photo_base64);
    if (photo === null) return json({ error: 'bad_photo' }, 400);

    const student = await deps.store.findStudentById(caller.studentId);
    if (student === null) return json({ error: 'unauthorized' }, 401);
    const profile = student.profile_complete ? null : readProfile(body as Record<string, unknown>);
    if (!student.profile_complete && profile === null) return json({ error: 'bad_profile' }, 400);

    const existing = await deps.store.getEnrolment(caller.studentId);
    if (existing?.status === 'approved') return json({ error: 'already_approved' }, 409);

    if (profile !== null) await deps.store.completeProfile(caller.studentId, profile);
    const status: EnrolmentStatus = existing?.status === 'rejected' ? 'pending' : 'approved';
    const saved = await deps.store.saveEnrolment(caller, phone, photo, status);
    return json({ status: saved.status, flags: saved.flags });
  } catch (error) {
    console.error('enrol failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}

export async function handleEnrolmentStatus(req: Request, deps: EnrolDeps): Promise<Response> {
  if (req.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
  try {
    const caller = await authenticate(req, deps.store);
    if (caller === null) return json({ error: 'unauthorized' }, 401);
    const student = await deps.store.findStudentById(caller.studentId);
    if (student === null) return json({ error: 'unauthorized' }, 401);
    const enrolment = await deps.store.getEnrolment(caller.studentId);
    return json({
      status: enrolment?.status ?? 'none',
      flags: enrolment?.flags ?? [],
      student: { name: student.name, roll_number: student.roll_number, branch: student.branch, year: student.year, email: student.college_email, profile_complete: student.profile_complete },
    });
  } catch (error) {
    console.error('enrolment-status failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}
