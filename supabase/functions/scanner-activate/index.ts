// POST /functions/v1/scanner-activate
//
// A guard installs the scanner app and types the one-time code an admin generated (PRD A6). This swaps the
// code for the scanner's own token, and returns the key set, revocation list and guards it needs to start.
// The rules and the exact request and reply are in _shared/scanner_activate.ts; the SQL is in
// _shared/pg_sync_store.ts.
//
// Secrets and settings (supabase secrets set ...):
//   SUPABASE_DB_URL        set by Supabase for every function
//   COLLEGE_KEYSET_JSON    optional; the public key set document (docs/credential-spec.md section 8)
//
// Scanners have no Supabase login yet, so verify_jwt = false in config.toml: the code is the credential.

import postgres from 'postgres';
import { parseKeySet } from '../_shared/credential.ts';
import type { KeySetDocument } from '../_shared/credential.ts';
import { PgSyncStore, postgresJsDb } from '../_shared/pg_sync_store.ts';
import type { PostgresJsLike } from '../_shared/pg_sync_store.ts';
import { handleScannerActivate } from '../_shared/scanner_activate.ts';

declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (req: Request) => Response | Promise<Response>): unknown;
};

function loadKeySet(): KeySetDocument | null {
  const raw = Deno.env.get('COLLEGE_KEYSET_JSON');
  if (!raw) return null;
  const doc = JSON.parse(raw) as KeySetDocument;
  parseKeySet(doc); // throws on a malformed set, so a bad setting stops the function at start-up
  return doc;
}

const dbUrl = Deno.env.get('SUPABASE_DB_URL');
if (!dbUrl) throw new Error('SUPABASE_DB_URL is not set');

const sql = postgres(dbUrl, { max: 3, prepare: false });
const store = new PgSyncStore(postgresJsDb(sql as unknown as PostgresJsLike));
const keySet = loadKeySet();

Deno.serve((req) => handleScannerActivate(req, { store, keySet }));
