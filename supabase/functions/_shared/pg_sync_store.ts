// The Postgres side of scanner-sync: the SyncStore that scanner_sync.ts uses, written as plain SQL
// against the tables in supabase/migrations/20261021000000_init.sql.
//
// It talks to the database through the tiny `Db` interface so that the same code runs in the Edge
// Function (postgres.js, see postgresJsDb) and in tests (PGlite, a real Postgres inside Node).

import type { ActivatedScanner, ActivateStore, ActivationIssuer, PendingActivation } from './scanner_activate.ts';
import type { GuardRecord, Rejection, SaveResult, ScanRow, ScannerRecord, SyncStore } from './scanner_sync.ts';

export interface Db {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<T[]>;
  /** Runs [fn] in one transaction: all its statements take effect, or none do. */
  transaction<T>(fn: (db: Db) => Promise<T>): Promise<T>;
}

/** What `postgres` (postgres.js) offers that this file uses. */
export interface PostgresJsLike {
  unsafe(text: string, params?: unknown[]): Promise<unknown[]>;
  begin<T>(fn: (tx: PostgresJsLike) => Promise<T>): Promise<T>;
}

export function postgresJsDb(sql: PostgresJsLike): Db {
  return {
    query: async <T>(text: string, params: unknown[] = []) => (await sql.unsafe(text, params)) as T[],
    transaction: <T>(fn: (db: Db) => Promise<T>) => sql.begin((tx) => fn(postgresJsDb(tx))),
  };
}

export class PgSyncStore implements SyncStore, ActivateStore, ActivationIssuer {
  db: Db;

  constructor(db: Db) {
    this.db = db;
  }

  async findScannerByTokenHash(tokenHash: string): Promise<ScannerRecord | null> {
    const rows = await this.db.query<ScannerRecord>('select id, gate, enabled from public.scanners where token_hash = $1', [tokenHash]);
    return rows[0] ?? null;
  }

  async saveScans(scanner: ScannerRecord, rows: ScanRow[]): Promise<SaveResult> {
    return await this.db.transaction(async (tx) => {
      const studentIds = [...new Set(rows.flatMap((r) => (r.student_id === null ? [] : [r.student_id])))];
      const rolls = [...new Set(rows.flatMap((r) => (r.roll_number === null ? [] : [r.roll_number])))];
      const guardIds = [...new Set(rows.map((r) => r.guard_id))];

      const knownStudents = new Set(
        (await tx.query<{ id: string }>('select id::text as id from public.students where id = any($1::bigint[])', [studentIds])).map((r) => Number(r.id)),
      );
      const studentByRoll = new Map(
        (await tx.query<{ roll_number: string; id: string }>('select roll_number, id::text as id from public.students where roll_number = any($1::text[])', [rolls])).map(
          (r) => [r.roll_number, Number(r.id)] as const,
        ),
      );
      const knownGuards = new Set((await tx.query<{ id: string }>('select id from public.guards where id = any($1::text[])', [guardIds])).map((r) => r.id));

      const rejected: Rejection[] = [];
      const attempted: string[] = [];
      for (const r of rows) {
        // A guard the server does not know is refused rather than invented: the scanner keeps the row.
        if (!knownGuards.has(r.guard_id)) {
          rejected.push({ scan_id: r.scan_id, reason: 'unknown_guard' });
          continue;
        }
        // The student id the scanner read from the pass, else whoever the roll number names. A pass for
        // someone not on the roster is still an exit that happened: it is kept by roll number and
        // resolved (or flagged) when the outpass is exported.
        let studentId: number | null = null;
        if (r.student_id !== null && knownStudents.has(r.student_id)) studentId = r.student_id;
        else if (r.roll_number !== null) studentId = studentByRoll.get(r.roll_number) ?? null;
        if (studentId === null && r.roll_number === null) {
          rejected.push({ scan_id: r.scan_id, reason: 'unknown_student' });
          continue;
        }

        await tx.query(
          `insert into public.scans (scan_id, scanned_at, student_id, roll_number, type, gate, scanner_id, guard_id, entry_method)
           values ($1::uuid, $2::timestamptz, $3::bigint, $4::text, $5::text, $6::text, $7::text, $8::text, $9::text)
           on conflict (scan_id) do nothing`,
          [r.scan_id, r.scanned_at, studentId, r.roll_number, r.type, r.gate, scanner.id, r.guard_id, r.entry_method],
        );
        attempted.push(r.scan_id);
      }

      // Not "what we just inserted" but "what is stored": a row sent again after a lost reply was
      // inserted by the first attempt, and must be named again so the scanner can delete it.
      const stored =
        attempted.length === 0
          ? []
          : (await tx.query<{ scan_id: string }>('select scan_id::text as scan_id from public.scans where scan_id = any($1::uuid[])', [attempted])).map((r) => r.scan_id);
      return { stored, rejected };
    });
  }

  async findPendingActivation(codeHash: string): Promise<PendingActivation | null> {
    const rows = await this.db.query<PendingActivation>(
      'select id, name, gate, enabled from public.scanners where activation_code_hash = $1 and activation_expires_at > now()',
      [codeHash],
    );
    return rows[0] ?? null;
  }

  async consumeActivation(codeHash: string, tokenHash: string): Promise<ActivatedScanner | null> {
    // One statement checks the code, clears it and stores the token, so two requests with the same code
    // cannot both succeed: the second finds no row to update.
    const rows = await this.db.query<ActivatedScanner>(
      `update public.scanners
          set token_hash = $2, activation_code_hash = null, activation_expires_at = null
        where activation_code_hash = $1 and activation_expires_at > now() and enabled
        returning id, name, gate`,
      [codeHash, tokenHash],
    );
    return rows[0] ?? null;
  }

  async setActivationCode(scannerId: string, codeHash: string, ttlMinutes: number): Promise<boolean> {
    const rows = await this.db.query(
      `update public.scanners
          set activation_code_hash = $2, activation_expires_at = now() + make_interval(mins => $3::int)
        where id = $1
        returning id`,
      [scannerId, codeHash, ttlMinutes],
    );
    return rows.length === 1;
  }

  async touchScanner(scannerId: string): Promise<void> {
    await this.db.query('update public.scanners set last_sync_at = now() where id = $1', [scannerId]);
  }

  async latestRevocationList(): Promise<string | null> {
    const rows = await this.db.query<{ encoded: string }>('select encoded from public.revocation_lists order by seq desc limit 1');
    return rows[0]?.encoded ?? null;
  }

  async guardsFor(scannerId: string): Promise<GuardRecord[]> {
    return await this.db.query<GuardRecord>(
      'select id, name, pin_hash from public.guards where enabled and (scanner_id is null or scanner_id = $1) order by id',
      [scannerId],
    );
  }
}
