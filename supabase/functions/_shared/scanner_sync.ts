// The rules of POST /functions/v1/scanner-sync, kept apart from Deno and from the database so that they
// can be tested directly. supabase/functions/scanner-sync/index.ts wires this to Postgres.
//
// The contract (what the Dart scanner in apps/scanner_app/lib/src/sync_client.dart sends and expects):
//
//   Request   POST, Authorization: Bearer <scanner token>
//     { "scans": [ { "scan_id": "<uuid>", "scanned_at": "2026-11-03T07:32:14Z",
//                    "student_id": 1042 | null, "roll_number": "25071A0001" | null,
//                    "type": "OUT", "gate": "Main", "guard_id": "G-03",
//                    "entry_method": "scan" | "manual" } ],
//       "visitors": [] }                       // visitors are not stored yet
//
//   Reply 200
//     { "accepted_scan_ids": [ ... ],          // every scan_id now stored, including ones stored before
//       "rejected": [ { "scan_id": "...", "reason": "..." } ],   // rows that are not stored, and why
//       "keyset": { ... } | null,              // docs/credential-spec.md section 8
//       "revocation_list": "DR1...." | null,
//       "guards": [ { "id", "name", "pin_hash" } ],
//       "server_time": 1793000000 }
//
//   Errors    401 no or unknown token, 403 scanner disabled, 405 not POST, 400 body is not
//             { scans: [...] }, 413 more than 500 scans or a body over 1 MB. All are { "error": "..." }.
//
// The scanner deletes a row from its phone only when the row's id is in accepted_scan_ids. So a row
// that is not stored must never be named there, and a row that is stored must always be named again
// if it is sent again (the reply to the first attempt may have been lost).

import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import type { KeySetDocument } from './credential.ts';

export const MAX_SCANS_PER_REQUEST = 500;
const MAX_BODY_CHARS = 1_000_000;

export type ScanType = 'OUT' | 'ENTRY_NO_CARD' | 'VISITOR';
export type EntryMethod = 'scan' | 'manual';

export interface ScannerRecord {
  id: string;
  gate: string;
  enabled: boolean;
}

export interface GuardRecord {
  id: string;
  name: string;
  pin_hash: string;
}

/** A scan that passed validation, in the form it is stored. */
export interface ScanRow {
  scan_id: string;
  /** UTC, `2026-11-03T07:32:14.000Z`. */
  scanned_at: string;
  student_id: number | null;
  /** Upper case, as in students.roll_number. */
  roll_number: string | null;
  type: ScanType;
  gate: string;
  guard_id: string;
  entry_method: EntryMethod;
}

export interface Rejection {
  scan_id: string;
  reason: string;
}

export interface SaveResult {
  /** The scan_ids that are stored after this call, whether they were stored now or earlier. */
  stored: string[];
  /** Rows the database could not take because they point at something that does not exist. */
  rejected: Rejection[];
}

/** What the handler needs from storage. */
export interface SyncStore {
  /** The scanner whose token hashes to [tokenHash] (lower-case hex SHA-256), or null. */
  findScannerByTokenHash(tokenHash: string): Promise<ScannerRecord | null>;
  /** Stores the rows, once each (a row whose scan_id exists is left as it is). */
  saveScans(scanner: ScannerRecord, rows: ScanRow[]): Promise<SaveResult>;
  /** Records that this scanner just synced. */
  touchScanner(scannerId: string): Promise<void>;
  /** The newest published revocation list (`DR1.` text), or null if none has been published. */
  latestRevocationList(): Promise<string | null>;
  /** Enabled guards who may use this scanner, for offline PIN login. */
  guardsFor(scannerId: string): Promise<GuardRecord[]>;
}

export interface SyncDeps {
  store: SyncStore;
  /** The college public keys scanners should trust; null if none is configured. */
  keySet: KeySetDocument | null;
  /** Unix seconds; tests replace it. */
  now?: () => number;
}

/** How a scanner token is stored: lower-case hex SHA-256 of its UTF-8 bytes in scanners.token_hash. */
export function hashToken(token: string): string {
  return bytesToHex(sha256(new TextEncoder().encode(token)));
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
const SCAN_TYPES: readonly string[] = ['OUT', 'ENTRY_NO_CARD', 'VISITOR'];
const ENTRY_METHODS: readonly string[] = ['scan', 'manual'];
const EARLIEST_MS = Date.UTC(2020, 0, 1);
const MAX_FUTURE_MS = 24 * 3600 * 1000;

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

function isObject(x: unknown): x is Record<string, unknown> {
  return typeof x === 'object' && x !== null && !Array.isArray(x);
}

function text(x: unknown, max: number): string | null {
  if (typeof x !== 'string') return null;
  const t = x.trim();
  return t.length >= 1 && t.length <= max ? t : null;
}

/** Checks one scan from the request. Returns the row to store, or the reason it cannot be stored. */
export function validateScan(raw: unknown, nowMs: number): { row: ScanRow } | { rejection: Rejection } {
  const id = isObject(raw) && typeof raw.scan_id === 'string' ? raw.scan_id : '';
  const reject = (reason: string) => ({ rejection: { scan_id: id, reason } });
  if (!isObject(raw)) return reject('not_an_object');
  if (!UUID.test(id)) return reject('bad_scan_id');

  const at = raw.scanned_at;
  if (typeof at !== 'string' || !ISO.test(at)) return reject('bad_time');
  const ms = Date.parse(at);
  if (Number.isNaN(ms) || ms < EARLIEST_MS || ms > nowMs + MAX_FUTURE_MS) return reject('bad_time');

  let studentId: number | null = null;
  if (raw.student_id !== null && raw.student_id !== undefined) {
    if (typeof raw.student_id !== 'number' || !Number.isSafeInteger(raw.student_id) || raw.student_id < 1) return reject('bad_student_id');
    studentId = raw.student_id;
  }
  let roll: string | null = null;
  if (raw.roll_number !== null && raw.roll_number !== undefined && raw.roll_number !== '') {
    const r = text(raw.roll_number, 16);
    if (r === null) return reject('bad_roll_number');
    roll = r.toUpperCase();
  }
  if (studentId === null && roll === null) return reject('no_student');

  if (typeof raw.type !== 'string' || !SCAN_TYPES.includes(raw.type)) return reject('bad_type');
  if (typeof raw.entry_method !== 'string' || !ENTRY_METHODS.includes(raw.entry_method)) return reject('bad_entry_method');
  const gate = text(raw.gate, 64);
  if (gate === null) return reject('bad_gate');
  const guard = text(raw.guard_id, 32);
  if (guard === null) return reject('bad_guard_id');

  return {
    row: {
      scan_id: id.toLowerCase(),
      scanned_at: new Date(ms).toISOString(),
      student_id: studentId,
      roll_number: roll,
      type: raw.type as ScanType,
      gate,
      guard_id: guard,
      entry_method: raw.entry_method as EntryMethod,
    },
  };
}

function bearerToken(req: Request): string | null {
  const header = req.headers.get('authorization') ?? '';
  const m = /^Bearer\s+(\S{8,512})$/i.exec(header);
  return m ? m[1] : null;
}

export async function handleScannerSync(req: Request, deps: SyncDeps): Promise<Response> {
  const now = deps.now ?? (() => Math.floor(Date.now() / 1000));
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  try {
    // Who is asking comes first: nobody else gets to make the server read a request body.
    const token = bearerToken(req);
    if (token === null) return json({ error: 'unauthorized' }, 401);
    const scanner = await deps.store.findScannerByTokenHash(hashToken(token));
    if (scanner === null) return json({ error: 'unauthorized' }, 401);
    if (!scanner.enabled) return json({ error: 'scanner_disabled' }, 403);

    const bodyText = await req.text();
    if (bodyText.length > MAX_BODY_CHARS) return json({ error: 'body_too_large' }, 413);
    let body: unknown;
    try {
      body = JSON.parse(bodyText);
    } catch {
      return json({ error: 'body_not_json' }, 400);
    }
    if (!isObject(body) || !Array.isArray(body.scans)) return json({ error: 'scans_missing' }, 400);
    if (body.scans.length > MAX_SCANS_PER_REQUEST) return json({ error: 'too_many_scans', max: MAX_SCANS_PER_REQUEST }, 413);

    const nowMs = now() * 1000;
    const rows: ScanRow[] = [];
    const rejected: Rejection[] = [];
    // The ids exactly as the scanner wrote them: it matches the reply against its own spelling.
    const sentAs = new Map<string, string>();
    for (const raw of body.scans) {
      const checked = validateScan(raw, nowMs);
      if ('row' in checked) {
        rows.push(checked.row);
        sentAs.set(checked.row.scan_id, (raw as { scan_id: string }).scan_id);
      } else {
        rejected.push(checked.rejection);
      }
    }

    const saved = rows.length > 0 ? await deps.store.saveScans(scanner, rows) : { stored: [], rejected: [] };
    await deps.store.touchScanner(scanner.id);
    const [revocationList, guards] = await Promise.all([deps.store.latestRevocationList(), deps.store.guardsFor(scanner.id)]);

    return json({
      // Only ids that were in this request, spelled as the scanner spelled them.
      accepted_scan_ids: [...new Set(saved.stored)].flatMap((id) => (sentAs.has(id) ? [sentAs.get(id) as string] : [])),
      rejected: [...rejected, ...saved.rejected],
      keyset: deps.keySet,
      revocation_list: revocationList,
      guards,
      server_time: now(),
    });
  } catch (error) {
    // Never echo the cause: it may contain row data or SQL.
    console.error('scanner-sync failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'server_error' }, 500);
  }
}
