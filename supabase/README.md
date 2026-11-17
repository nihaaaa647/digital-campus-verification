# Supabase backend, and the local server that stands in for it

| Path | What |
|---|---|
| `migrations/20261021000000_init.sql` | tables, views, row level security, roster-only sign-up hook |
| `migrations/20261021000100_retention_cron.sql` | nightly deletion of old scans (A11) |
| `seed.sql` | development data: five roster students, scanner `SC-DEV` (token `dev-token`), scanner `SC-NEW` (no token yet), guard `G-DEV`. Never load it into a real project. |
| `functions/_shared/credential.ts`, `cbor.ts` | credential format, signing, verification (tested against the shared vectors) |
| `functions/_shared/signer.ts` | where the college key lives (function secret now, KMS later) |
| `functions/_shared/scanner_sync.ts`, `pg_sync_store.ts` | `scanner-sync`: the rules, and the SQL behind them |
| `functions/_shared/scanner_activate.ts` | `scanner-activate`: swaps a one-time code for the scanner's token, gate and the college key set; also issues the codes |
| `functions/_shared/student_auth.ts` | student sign-in by email and a 6-digit code, sessions, `authenticate` (the one place that says who a request is from) |
| `functions/_shared/enrolment.ts` | `enrol` (phone number and photo) and `enrolment-status` |
| `functions/_shared/issue_credential.ts` | `issue-credential`: the pass for an approved student, bound to the phone's key; a second phone replaces the first |
| `functions/_shared/pg_student_store.ts` | the SQL behind the three above |
| `functions/dev/` | **the local server**: `serve.ts` (all of the above over HTTP, plus the admin page), `admin.ts` (the admin page and its API), `local_db.ts` (a real Postgres in-process with the migration and seed, and `../dev/dev_auth.sql`, the local-only tables that stand in for Supabase Auth), `dev_signer.ts` (the public test college key), `test_pass.ts` (a test QR shown on the PC screen) |
| `functions/scanner-sync/index.ts`, `scanner-activate/index.ts` | Edge Function wiring for Supabase (Deno), **never run** |
| `functions/issue-credential/index.ts` | still a 501 stub; its header says how to wire `_shared/issue_credential.ts` to Supabase |
| `config.toml` | local CLI config |

## Run the local server (no Docker, no Supabase CLI, no internet)

```bash
cd supabase/functions
npm install
npm run dev:server                 # http://127.0.0.1:8787   admin page at /admin
```

| Setting | Effect |
|---|---|
| `PORT=8790` | another port |
| `HOST=0.0.0.0` | reachable from phones on the same Wi-Fi; prints the laptop's address |
| `ADMIN_PASSWORD=...` | the admin website's password. Without it a random one is made and printed at start-up. The website **always** asks for it |
| `FRESH=1` | forget saved data and start from the seed |
| `MEMORY=1` | keep nothing on disk (what the integration tests use) |
| `DEMO_OTP=0` | do not put the sign-in code in the reply; it is printed in the server window only |

Data is kept in `supabase/.dev-data` (git-ignored); a database damaged by a hard stop is moved aside, not deleted. A phone on USB reaches the server with `adb reverse tcp:8787 tcp:8787`. The walk-through is `docs/DEMO.md`.

Endpoints (all under `/functions/v1/`): `auth-request-otp`, `auth-verify-otp`, `auth-sign-out`, `enrol`, `enrolment-status`, `issue-credential`, `scanner-activate`, `scanner-sync`. Development routes, **all behind the admin login** (`dev/admin_auth.ts`: a password sets an HttpOnly, SameSite=Strict session cookie; five wrong tries lock sign-in for a minute; a scanner's token or HTTP Basic opens nothing): `/admin` (the website), `/admin/api/*` (state, add student, approve or reject an enrolment, a student's photo, add a scanner, make an activation code, `exits` and `exits.csv` with `from`, `to` and `q` filters), `/_dev/scans`, `/_dev/activation-code?scanner=SC-NEW`, `/_dev/test-pass`.

## What has been run

- **`npm test` (from `functions/`) runs 305 tests under Node**: the credential format against `spec/test-vectors/v1.json` (59), `scanner-sync` rules (55), its SQL on a real Postgres (35), the production postgres.js adapter over a real socket (10), `scanner-activate` rules (25) and SQL (17), the student flow (35), the admin website's API and exit search (36), its login (20), the PC test pass (2). Deliberately breaking rules (ignore a repeat scan, name only stored ids, drop the CSV byte order mark) makes tests fail; the tests for the other rules have not all been checked that way.
- **The student flow** (`_shared/student_flow.test.ts`): a code works once and only for its email; five wrong tries lock it; a roster email only; a session lasts 30 days and sign-out ends it; a photo is checked (JPEG or PNG, 1 KB to 1.5 MB) and kept on the server with its 16-byte hash going into the pass; **a pass is issued only for an approved, active student**; a pass issued by the server is accepted by the scanner's `verifyScan` and a copy on another key is refused; a second phone revokes the first and its `iat` is later than the revocation, so it is not caught by it; a failure while signing changes nothing.
- **The initial migration has run**, on PostgreSQL 18 through PGlite (Postgres compiled to WebAssembly), with minimal stand-ins for Supabase's `auth` schema and roles (`supabase/dev/dev_auth.sql` adds the local-only tables). It has **not** been run by the Supabase CLI or on a Supabase project.
- **The Dart apps against this server:** the scanner's sync (`sync_server_integration_test.dart`), the student app's whole journey (`student_server_integration_test.dart`), and the whole loop in one test (`apps/scanner_app/test/full_loop_integration_test.dart`): activate a scanner with a code, sign a student in, enrol, approve, issue, scan the pass with the key set the server gave on activation, sync the exit, read it on the admin page and in the CSV.
- **Not run:** the Edge Function wiring files (Deno is not installed here), `migrations/20261021000100_retention_cron.sql` (needs `pg_cron`), `config.toml` through the CLI, the RLS policies with real JWTs, and `issue-credential/index.ts`.

## The local login is not Supabase Auth

`student_auth.ts` keeps codes (hashed with the email, 10 minutes, 5 tries, 30 seconds between codes) and sessions (random 43-character token, only its hash stored, 30 days) in three local tables, and shows the code in the reply in demo mode because there is no mail service. On Supabase the same two steps are Supabase Auth's email OTP and JWT sessions, and the roster check is the `hook_before_user_created` function in the first migration. Everything else asks one question, "who is this request from?", answered by `authenticate`, so moving to Supabase Auth means replacing that one function and `StudentApi` in the student app.

## scanner-sync

`POST /functions/v1/scanner-sync` with `Authorization: Bearer <scanner token>`. Full contract at the top of `functions/_shared/scanner_sync.ts`.

- A scanner token is stored as the lower-case hex SHA-256 in `scanners.token_hash`. Unknown token: 401. `enabled = false`: 403.
- Up to 500 scans per request. Each is checked (uuid, ISO time between 2020 and a day ahead, student id or roll number, known type and entry method, gate, guard) and stored once by `scan_id` (`on conflict do nothing`). The reply's `accepted_scan_ids` names every id that is **now stored**, including ones stored by an earlier attempt, spelled as the scanner spelled it, and never an id that was not in the request. The scanner deletes a row only when it is named, so a lost reply is harmless.
- A row that cannot be stored is listed in `rejected` with a reason and is not named in `accepted_scan_ids`, and does not hold up the others: `bad_time`, `bad_scan_id`, `no_student`, `unknown_guard`, `unknown_student`, and so on. The scanner keeps such rows.
- **Who a scan belongs to:** the student id on the pass if it is on the roster, else the roll number's student. A pass for someone not on the roster is kept by roll number (the exit happened) and resolved or flagged at export. The scanner is taken from the token, not from the request.
- **Guards:** an unknown `guard_id` is refused, not invented. The scanner app sends the placeholder `G-DEV` until guard login exists; `seed.sql` creates it for development only.
- The reply also carries `keyset` (from the `COLLEGE_KEYSET_JSON` secret, public keys only), the newest `revocation_list`, the enabled `guards` for this scanner (with PIN hashes, G1) and `server_time`. The scanner reads only `accepted_scan_ids` and `server_time` so far.
- `last_sync_at` is updated on every authorised request, even an empty one. Visitors are accepted in the request but not stored yet.

## scanner-activate

An admin makes a code for a scanner (admin page, or `issueActivationCode`); the code is 8 characters from an alphabet without 0, 1, I and O, shown as `ABCD-EFGH`, stored only as a hash, valid once for 15 minutes. `POST /functions/v1/scanner-activate {"code": "..."}` swaps it, in one atomic statement, for `{scanner_id, name, gate, token, keyset, server_time}`: the scanner's own token (shown once, stored as `sha256` in `scanners.token_hash`, replacing any earlier token) and the college public key set. 404 for a wrong, expired or used code (one answer for all three), 403 for a disabled scanner.

## First run on Supabase

Not done. The steps, in order:

```bash
supabase start            # needs Docker
supabase db reset         # applies the migrations and seed.sql; fix whatever it reports first
supabase functions serve
```

Secrets:

```bash
supabase secrets set COLLEGE_SIGNING_KEY_HEX=<64 hex chars> COLLEGE_SIGNING_KEY_VERSION=1   # a generated key, not the test key
supabase secrets set COLLEGE_KEYSET_JSON='{"v":1,"current":1,"keys":[{"kv":1,"alg":"ES256","pub":"<base64url, 33 bytes>"}]}'
```

Before the first deploy, run `deno check` on the `index.ts` files once Deno is installed, wire `issue-credential/index.ts` (its header lists the three steps), replace `authenticate` and the local login tables with Supabase Auth, and put the admin page behind real admin accounts.

## Things to know before building on this

- The local server signs with the **public test key kv 2** from `spec/test-vectors/v1.json`, and hands scanners the vectors' key set. Anyone who reads the repository can forge a pass for it. A deployment needs its own key.
- Supabase's built-in mailer only sends to team members, so student sign-in emails need custom SMTP (Auth > SMTP settings) before onboarding anyone.
- Free-tier projects pause after about a week of inactivity, and Edge Functions have a short CPU limit. Both are fine for these endpoints, not for building large Excel files.
- Admin and read-only roles come from `app_metadata.role` on the user, which only the service role can set.
- A scan row the server refuses stays on the scanner and is retried forever (see the scanner README). `unknown_guard` is the likely cause: the guard list the scanner holds must come from `scanner-sync`.
- The admin page shows photos from the local `dev_photos` table; on Supabase they belong in Storage with signed URLs.
