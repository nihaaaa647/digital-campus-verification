// The rules of POST /functions/v1/scanner-activate, kept apart from Deno and from the database so they can
// be tested directly. supabase/functions/scanner-activate/index.ts wires this to Postgres.
//
// How a scanner gets its identity (PRD A6): an admin generates a one-time code for a scanner; a guard
// types it into the scanner app; this function swaps the code for a long random token that the scanner
// uses from then on (`Authorization: Bearer <token>` on scanner-sync). Only the token's SHA-256 is stored.
//
//   Request   POST { "code": "K7QM-29XD" }        (case, spaces and the hyphen do not matter)
//
//   Reply 200
//     { "scanner_id": "SC-01", "name": "Main gate 1", "gate": "Main",
//       "token": "<43 characters, shown once>",
//       "keyset": { ... } | null,                 // docs/credential-spec.md section 8
//       "revocation_list": "DR1...." | null,
//       "guards": [ { "id", "name", "pin_hash" } ],
//       "server_time": 1793000000 }
//
//   Errors    404 the code is unknown, expired, already used or malformed (the same answer for all four, so
//             a wrong guess teaches nothing), 403 the scanner is disabled, 405 not POST,
//             400 body is not { code: ... }, 413 body over 4 KB.
//
// A code works once: the same statement that checks it also clears it and stores the token, so two
// requests with the same code cannot both succeed. Activating a scanner that already has a token replaces
// the token, and the old one stops working at once.

import { toBase64Url } from './credential.ts';
import type { KeySetDocument } from './credential.ts';
import { hashToken } from './scanner_sync.ts';
import type { GuardRecord } from './scanner_sync.ts';

/** 32 characters, so one random byte masked to 5 bits picks one with no bias. No 0, 1, I or O: they look alike. */
export const ACTIVATION_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const ACTIVATION_CODE_LENGTH = 8;
export const DEFAULT_ACTIVATION_TTL_MINUTES = 15;
const MAX_BODY_CHARS = 4096;

export interface PendingActivation {
  id: string;
  name: string;
  gate: string;
  enabled: boolean;
}

export interface ActivatedScanner {
  id: string;
  name: string;
  gate: string;
}

/** What the activation handler needs from storage. */
export interface ActivateStore {
  /** The scanner holding an unexpired activation code with this hash, or null. */
  findPendingActivation(codeHash: string): Promise<PendingActivation | null>;
  /**
   * In one atomic step: if the code is still valid and the scanner enabled, store [tokenHash], clear the
   * code, and return the scanner; otherwise change nothing and return null.
   */
  consumeActivation(codeHash: string, tokenHash: string): Promise<ActivatedScanner | null>;
  latestRevocationList(): Promise<string | null>;
  guardsFor(scannerId: string): Promise<GuardRecord[]>;
}

/** What admin tooling needs to hand a guard a code. */
export interface ActivationIssuer {
  /** Stores the hash of a new code on the scanner, valid for [ttlMinutes] from now (database time). False if there is no such scanner. */
  setActivationCode(scannerId: string, codeHash: string, ttlMinutes: number): Promise<boolean>;
}

export interface ActivateDeps {
  store: ActivateStore;
  keySet: KeySetDocument | null;
  now?: () => number;
  /** Tests replace the random token. */
  newToken?: () => string;
}

function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

/** A fresh code in the form shown to people: `K7QM-29XD`. */
export function generateActivationCode(random: (n: number) => Uint8Array = randomBytes): string {
  const bytes = random(ACTIVATION_CODE_LENGTH);
  let code = '';
  for (const b of bytes) code += ACTIVATION_ALPHABET[b & 31];
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** What is hashed and compared: upper case, no spaces or hyphens. Null if it cannot be a code. */
export function normalizeActivationCode(input: unknown): string | null {
  if (typeof input !== 'string') return null;
  const code = input.toUpperCase().replace(/[\s-]/g, '');
  if (code.length !== ACTIVATION_CODE_LENGTH) return null;
  for (const ch of code) if (!ACTIVATION_ALPHABET.includes(ch)) return null;
  return code;
}

/** The scanner token: 32 random bytes, 43 URL-safe characters. */
export function mintToken(random: (n: number) => Uint8Array = randomBytes): string {
  return toBase64Url(random(32));
}

/** Gives [scannerId] a new activation code and returns it. Replaces any code it had. For admin tooling and tests. */
export async function issueActivationCode(
  issuer: ActivationIssuer,
  scannerId: string,
  ttlMinutes: number = DEFAULT_ACTIVATION_TTL_MINUTES,
  random: (n: number) => Uint8Array = randomBytes,
): Promise<string | null> {
  const code = generateActivationCode(random);
  const stored = await issuer.setActivationCode(scannerId, hashToken(normalizeActivationCode(code) as string), ttlMinutes);
  return stored ? code : null;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

export async function handleScannerActivate(req: Request, deps: ActivateDeps): Promise<Response> {
  const now = deps.now ?? (() => Math.floor(Date.now() / 1000));
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  try {
    const text = await req.text();
    if (text.length > MAX_BODY_CHARS) return json({ error: 'body_too_large' }, 413);
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return json({ error: 'body_not_json' }, 400);
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body) || !('code' in body)) return json({ error: 'code_missing' }, 400);

    // A code that cannot possibly be one gets the same answer as a wrong one.
    const invalid = () => json({ error: 'invalid_or_expired_code' }, 404);
    const code = normalizeActivationCode((body as { code: unknown }).code);
    if (code === null) return invalid();
    const codeHash = hashToken(code);

    const pending = await deps.store.findPendingActivation(codeHash);
    if (pending === null) return invalid();
    if (!pending.enabled) return json({ error: 'scanner_disabled' }, 403);

    const token = (deps.newToken ?? mintToken)();
    const scanner = await deps.store.consumeActivation(codeHash, hashToken(token));
    if (scanner === null) return invalid(); // another request used the code between the check and now

    const [revocationList, guards] = await Promise.all([deps.store.latestRevocationList(), deps.store.guardsFor(scanner.id)]);
    return json({
      scanner_id: scanner.id,
      name: scanner.name,
      gate: scanner.gate,
      token,
      keyset: deps.keySet,
      revocation_list: revocationList,
      guards,
      server_time: now(),
    });
  } catch (error) {
    // Never echo the cause: it may contain SQL or secrets.
    console.error('scanner-activate failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}
