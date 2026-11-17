// A real Postgres for tests and for running scanner-sync on a laptop without Docker or the Supabase CLI:
// PGlite (Postgres compiled to WebAssembly) with the project's own migration and seed applied.
//
// Supabase's own pieces (the `auth` schema, a few roles) are not in plain Postgres, so minimal stand-ins
// are created first. They only have to exist for the migration to run; nothing here checks passwords.

import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import type { Db } from '../_shared/pg_sync_store.ts';

const root = new URL('../../', import.meta.url);

const SUPABASE_STAND_INS = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  create role supabase_auth_admin nologin;
  create schema auth;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text unique);
  create function auth.jwt() returns jsonb language sql stable
    as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
  create function auth.uid() returns uuid language sql stable
    as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
`;

/**
 * The initial migration, the local-only tables, and the development seed unless [seed] is false.
 * In memory by default (tests); with [dataDir] it is kept on disk and reused when the folder already holds a
 * database, so a demo does not lose its registrations when the server restarts.
 */
export async function createLocalDatabase(options: { seed?: boolean; dataDir?: string } = {}): Promise<PGlite> {
  const pg = options.dataDir ? new PGlite(options.dataDir) : new PGlite();
  await pg.waitReady;
  const existing = (await pg.query<{ t: string | null }>("select to_regclass('public.scans')::text as t")).rows[0].t;
  if (existing !== null) return pg;
  await pg.exec(SUPABASE_STAND_INS);
  await pg.exec(readFileSync(new URL('migrations/20261021000000_init.sql', root), 'utf8'));
  await pg.exec(readFileSync(new URL('dev/dev_auth.sql', root), 'utf8')); // local-only login and photo tables
  if (options.seed ?? true) await pg.exec(readFileSync(new URL('seed.sql', root), 'utf8'));
  return pg;
}

interface PGliteQueryable {
  query(text: string, params?: unknown[]): Promise<{ rows: unknown[] }>;
  transaction<T>(fn: (tx: PGliteQueryable) => Promise<T>): Promise<T>;
}

/** Lets the Db-based code run on PGlite. */
export function pgliteDb(pg: PGliteQueryable): Db {
  return {
    query: async <T>(text: string, params: unknown[] = []) => (await pg.query(text, params)).rows as T[],
    transaction: <T>(fn: (db: Db) => Promise<T>) => pg.transaction((tx) => fn(pgliteDb(tx))),
  };
}
