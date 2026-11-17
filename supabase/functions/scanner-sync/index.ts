// POST /functions/v1/scanner-sync
//
// The scanner calls this whenever it has a connection (PRD G9, G10, G14): it sends the exits it has
// saved and gets back the ids the server now holds, the clock, the key set, the revocation list and
// the guards. The rules, the exact request and reply, and the errors are in
// _shared/scanner_sync.ts; the SQL is in _shared/pg_sync_store.ts.
//
// Secrets and settings (supabase secrets set ...):
//   SUPABASE_DB_URL        set by Supabase for every function
//   COLLEGE_KEYSET_JSON    optional; the public key set document (docs/credential-spec.md section 8),
//                          for example {"v":1,"current":2,"keys":[{"kv":2,"alg":"ES256","pub":"..."}]}
//
// Scanners authenticate with their own token (verify_jwt = false in config.toml). The token is stored
// as its lower-case hex SHA-256 in scanners.token_hash.

import postgres from 'postgres';
import { parseKeySet } from '../_shared/credential.ts';
import type { KeySetDocument } from '../_shared/credential.ts';
import { PgSyncStore, postgresJsDb } from '../_shared/pg_sync_store.ts';
import type { PostgresJsLike } from '../_shared/pg_sync_store.ts';
import { handleScannerSync } from '../_shared/scanner_sync.ts';

declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (req: Request) => Response | Promise<Response>): unknown;
};

function loadKeySet(): KeySetDocument | null {
  const raw = Deno.env.get('COLLEGE_KEYSET_JSON');
  if (!raw) return null;
  const doc = JSON.parse(raw) as KeySetDocument;
  parseKeySet(doc); // throws on a malformed set, so a bad setting stops the function at start-up, not at the first sync
  return doc;
}

const dbUrl = Deno.env.get('SUPABASE_DB_URL');
if (!dbUrl) throw new Error('SUPABASE_DB_URL is not set');

// prepare: false keeps this working if the URL points at a transaction pooler.
const sql = postgres(dbUrl, { max: 3, prepare: false });
const store = new PgSyncStore(postgresJsDb(sql as unknown as PostgresJsLike));
const keySet = loadKeySet();

Deno.serve((req) => handleScannerSync(req, { store, keySet }));
