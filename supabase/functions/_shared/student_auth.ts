// Student login by email and one-time code (PRD S1), as the local server does it.
//
//   POST /functions/v1/auth-request-otp   { "email": "25071a66j1@vnrvjiet.in" }
//     200 { "sent": true, "dev_otp": "123456" }   dev_otp only when the server runs in demo mode
//     400 bad email   404 not a college email (the roll number at the college's domain)   429 asked again too soon
//
//   POST /functions/v1/auth-verify-otp    { "email": "...", "otp": "123456" }
//     200 { "access_token": "...", "expires_in": 2592000, "student": { name, roll_number, branch, year, email } }
//     401 wrong, expired or never requested (one answer for all)   429 five wrong tries used up
//
//   POST /functions/v1/auth-sign-out      Authorization: Bearer <access_token>      200 { "ok": true }
//
// On Supabase the same two steps are done by Supabase Auth (email OTP, JWT sessions) and the roster check is
// the `hook_before_user_created` function in the first migration; nothing here runs there. The rest of the
// system only needs the answer to "who is this request from?", which is `authenticate` below, so swapping
// Supabase Auth in later means changing that one function.

import { toBase64Url } from './credential.ts';
import { hashToken } from './scanner_sync.ts';

export const OTP_TTL_MINUTES = 10;
export const OTP_MAX_TRIES = 5;
export const OTP_MIN_SECONDS_BETWEEN = 30;
export const SESSION_TTL_DAYS = 30;

export interface RosterStudent {
  id: number;
  name: string;
  roll_number: string;
  branch: string;
  year: number;
  college_email: string;
  status: string;
  /** False until a student who signed up by roll-number email has given name, branch and year (enrolment.ts). */
  profile_complete: boolean;
}

/** The college's email domain. A student's email is their roll number at this domain: 25071a66j1@vnrvjiet.in. */
export const COLLEGE_EMAIL_DOMAIN = 'vnrvjiet.in';

/** What a roll number looks like: 25071A66J1 (five digits, a letter, four more), or a fresher's ADM26-00317. */
const ROLL_NUMBER = /^(\d{5}[A-Z][0-9A-Z]{4}|ADM\d{2}-\d{5})$/;

/**
 * The roll number an email stands for, upper-cased, or null if the email is not `<roll number>@<domain>`.
 * The one-time code then proves the mailbox, and so who the student is.
 */
export function rollFromEmail(email: string, domain: string = COLLEGE_EMAIL_DOMAIN): string | null {
  const at = email.lastIndexOf('@');
  if (at < 1 || email.slice(at + 1) !== domain.toLowerCase()) return null;
  const roll = email.slice(0, at).toUpperCase();
  return ROLL_NUMBER.test(roll) ? roll : null;
}

export interface Caller {
  studentId: number;
  authUserId: string;
}

export interface AuthStore {
  /** The student with this roll number, made (with an incomplete profile) if there is none yet. */
  findOrCreateStudent(rollNumber: string, email: string): Promise<RosterStudent>;
  /** Seconds since a code was last made for this email, or null if there is none. */
  secondsSinceLastOtp(email: string): Promise<number | null>;
  /** Stores a new code for the email (replacing any earlier one) with no tries used. */
  saveOtp(email: string, codeHash: string, ttlMinutes: number): Promise<void>;
  /** Uses up one try on the email's live code. Returns its hash while tries remain, 'locked' when they are gone, null if there is no live code. */
  takeOtpTry(email: string): Promise<{ codeHash: string } | 'locked' | null>;
  clearOtp(email: string): Promise<void>;
  /** The id of the (local stand-in for a Supabase) auth user for this email, made if it did not exist. */
  ensureAuthUser(email: string): Promise<string>;
  createSession(studentId: number, authUserId: string, tokenHash: string, ttlDays: number): Promise<void>;
  findSession(tokenHash: string): Promise<Caller | null>;
  endSession(tokenHash: string): Promise<void>;
}

export interface AuthDeps {
  store: AuthStore;
  /** Sends the code to the student. The local server prints it. */
  deliver: (email: string, code: string) => void | Promise<void>;
  /** The college's email domain; tests and other colleges replace it. */
  emailDomain?: string;
  /** Demo mode: put the code in the reply so the app can show it (there is no email service here). */
  exposeOtp?: boolean;
  /** Tests replace the random code and token. */
  newOtp?: () => string;
  newToken?: () => string;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

/** A uniformly random 6-digit code (no modulo bias). */
export function randomOtp(): string {
  const limit = 4_294_967_296 - (4_294_967_296 % 1_000_000);
  const buf = new Uint32Array(1);
  do crypto.getRandomValues(buf); while (buf[0] >= limit);
  return String(buf[0] % 1_000_000).padStart(6, '0');
}

export function randomToken(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
}

/** What is hashed: the code is only good for the email it was sent to. */
const otpHash = (email: string, code: string) => hashToken(`${email}:${code}`);

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function normalizeEmail(input: unknown): string | null {
  if (typeof input !== 'string') return null;
  const email = input.trim().toLowerCase();
  return email.length <= 254 && EMAIL.test(email) ? email : null;
}

async function readJson(req: Request): Promise<Record<string, unknown> | Response> {
  const text = await req.text();
  if (text.length > 10_000) return json({ error: 'body_too_large' }, 413);
  try {
    const body = JSON.parse(text);
    if (typeof body === 'object' && body !== null && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    // falls through
  }
  return json({ error: 'body_not_json' }, 400);
}

export async function handleRequestOtp(req: Request, deps: AuthDeps): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const body = await readJson(req);
    if (body instanceof Response) return body;
    const email = normalizeEmail(body.email);
    if (email === null) return json({ error: 'bad_email' }, 400);

    // Same rule as the sign-up hook on Supabase: only a college email, the roll number at the college's
    // domain, may have an account. (The error keeps its old name, `not_on_roster`, for the apps.)
    if (rollFromEmail(email, deps.emailDomain) === null) return json({ error: 'not_on_roster' }, 404);

    const age = await deps.store.secondsSinceLastOtp(email);
    if (age !== null && age < OTP_MIN_SECONDS_BETWEEN) {
      return json({ error: 'wait', retry_after_s: Math.ceil(OTP_MIN_SECONDS_BETWEEN - age) }, 429);
    }

    const code = (deps.newOtp ?? randomOtp)();
    await deps.store.saveOtp(email, await otpHash(email, code), OTP_TTL_MINUTES);
    await deps.deliver(email, code);
    return json(deps.exposeOtp ? { sent: true, dev_otp: code } : { sent: true });
  } catch (error) {
    console.error('auth-request-otp failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}

export async function handleVerifyOtp(req: Request, deps: AuthDeps): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const body = await readJson(req);
    if (body instanceof Response) return body;
    const email = normalizeEmail(body.email);
    const otp = typeof body.otp === 'string' ? body.otp.replace(/\s/g, '') : '';
    if (email === null || !/^\d{6}$/.test(otp)) return json({ error: 'invalid_or_expired_otp' }, 401);

    const attempt = await deps.store.takeOtpTry(email);
    if (attempt === 'locked') return json({ error: 'too_many_attempts' }, 429);
    if (attempt === null || attempt.codeHash !== (await otpHash(email, otp))) return json({ error: 'invalid_or_expired_otp' }, 401);

    const roll = rollFromEmail(email, deps.emailDomain);
    if (roll === null) return json({ error: 'invalid_or_expired_otp' }, 401);
    await deps.store.clearOtp(email); // a code works once
    const student = await deps.store.findOrCreateStudent(roll, email);

    const token = (deps.newToken ?? randomToken)();
    await deps.store.createSession(student.id, await deps.store.ensureAuthUser(email), await hashToken(token), SESSION_TTL_DAYS);
    return json({
      access_token: token,
      expires_in: SESSION_TTL_DAYS * 86400,
      student: { name: student.name, roll_number: student.roll_number, branch: student.branch, year: student.year, email, profile_complete: student.profile_complete },
    });
  } catch (error) {
    console.error('auth-verify-otp failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}

function bearer(req: Request): string | null {
  const m = /^Bearer\s+(\S{16,512})$/i.exec(req.headers.get('authorization') ?? '');
  return m ? m[1] : null;
}

/** Who a request is from, or null. Every student endpoint calls this first. */
export async function authenticate(req: Request, store: Pick<AuthStore, 'findSession'>): Promise<Caller | null> {
  const token = bearer(req);
  return token === null ? null : await store.findSession(await hashToken(token));
}

export async function handleSignOut(req: Request, deps: Pick<AuthDeps, 'store'>): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const token = bearer(req);
    if (token === null) return json({ error: 'unauthorized' }, 401);
    await deps.store.endSession(await hashToken(token));
    return json({ ok: true });
  } catch (error) {
    console.error('auth-sign-out failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}
