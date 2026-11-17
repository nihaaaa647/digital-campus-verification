# Digital Campus ID

A QR exit pass for the college gate: a student phone app, a guard scanner app and a backend, built on college-signed, device-bound credentials that verify offline. The product is described in the PRD; the stack choices are Flutter for both apps and Supabase for the backend.

**Where it stands:** a working local prototype of the whole loop, on a laptop and Android phones, with no Supabase, Docker or internet: a student signs up with their college email (`<roll number>@vnrvjiet.in`) and a 6-digit code, scans their ID card (name, branch and year are read on the phone), adds a phone number and a photo, and gets a pass signed by the college for the phone's own Keystore key at once (no per-student approval), a guard's scanner (activated with a one-time code) scans it offline (in **Verify** mode it only checks the pass; the guard switches to **Out pass** to record exits), saves the exit, shows it in a **view-only list on the guard's phone** (a guard cannot export student data) and syncs it, and the **admin website**, behind a login, shows every exit with the student's phone number, searches it, and exports CSV. **[`docs/DEMO.md`](docs/DEMO.md) is the walk-through and lists what is real and what is not.**

## Layout

| Path | What | State |
|---|---|---|
| [`docs/credential-spec.md`](docs/credential-spec.md) | The credential, QR and revocation format every component follows | written |
| [`spec/test-vectors/v1.json`](spec/test-vectors/v1.json) | Test keys, byte-exact encodings and 41 expected results | generated |
| [`tools/gen-vectors/`](tools/gen-vectors/gen.mjs) | Regenerates the vectors (`node tools/gen-vectors/gen.mjs`), deterministic, no dependencies | works |
| [`packages/credential_core/`](packages/credential_core) | Dart implementation shared by both apps | 68 tests pass |
| [`supabase/functions/_shared/`](supabase/functions/_shared) | TypeScript for the server: the credential format; `scanner-sync`, `scanner-activate`, student sign-in, enrolment and `issue-credential` (rules and SQL) | 305 tests pass (with `dev/`) |
| [`supabase/`](supabase) | Schema migrations, dev seed, config, the **local server** (`npm run dev:server`: every endpoint plus the admin page, on a real Postgres in-process) and the Edge Function wiring | the migration and all logic run on Postgres 18; the Supabase CLI and the Edge Function wiring have not been run (see below) |
| [`packages/campus_ui/`](packages/campus_ui) | Shared look of both apps: theme, meaning colours, avatar, pill, brand mark | 7 tests pass |
| [`apps/student_app/`](apps/student_app) | Student app | sign-in, enrolment with photo, waiting, the pass, renewal, sign-out; 150 tests pass; the pass screen and Keystore signer ran on a real phone, the new screens have only run in tests |
| [`apps/scanner_app/`](apps/scanner_app) | Guard scanner | activation, scan, verify, green/red screen, local scan log, sync; 250 tests pass; scan, log, sync, activation and the out pass list ran on a real phone; the Verify / Out pass switch is tested but not yet seen on a phone |
| [`docs/DEMO.md`](docs/DEMO.md) | The demo script, what is real and what is not, and what to do when it breaks | written |

The admin website is a prototype served by the local server (`/admin`), **behind a login**: enrolments with photos (approved automatically; it can reject one), the roster, scanners and one-time activation codes, and the exits with search, a day filter and CSV export. One shared password, no separate accounts or roles yet.

## What is verified and what is not

Verified by running it:

- The Dart package passes `dart analyze` and all 68 tests, using Dart SDK 3.13.6.
- The TypeScript code passes all 305 tests under Node 24: the credential format against the vectors (59), the `scanner-sync` rules (55) and SQL on a real Postgres engine (35), the production `postgres.js` database path over a real socket (10), `scanner-activate` (25 and 17), the student flow (46), the admin website's API (36), its login (20) and the PC test pass (2). Deliberately breaking "ignore a repeated scan" and "only name rows that are stored" fails 6 and 4 of them.
- Your initial migration runs on PostgreSQL 18 (PGlite, Postgres compiled to WebAssembly, with stand-ins for Supabase's `auth` schema and roles): all tables, policies and views are created and the dev seed loads. It was never run before this.
- `scanner-sync` is implemented and works end to end against that database. The Dart scanner (client, service and SQLite log) syncs into the real handler and SQL: rows are stored once, resolved to the student by roll number, a row for an unknown guard is refused and stays on the phone, and a repeat send after a "lost reply" creates no duplicates (`apps/scanner_app/test/sync_server_integration_test.dart`).
- Three independent ECDSA implementations (`node:crypto` in the generator, `@noble/curves` in TypeScript, `pointycastle` in Dart) produce identical signature bytes for every vector, and both implementations return the expected result for all 32 scan cases and 9 revocation-list cases.
- Both Flutter apps (Flutter 3.47.8): `android/` generated with `flutter create`, `minSdk = 26`, and `flutter analyze` is clean. The student app's 124 tests pass; 34 of them are the pass screen's: the Keystore signer against a fake of the Kotlin channel, the 30-second refresh, expiry, clock offset, every "can't show the pass" case, and scanner-side `verifyScan` checks on the QRs the screen draws. The scanner's 250 tests (158 of them from before activation) run every shared verify case through its own logic, check the red-screen titles against the spec table, and cover the hold times, debounce, clock offset and the scan log (a green screen only after the row is committed, and a red "not saved" screen if the write fails) and sync (rows are deleted only when the server names them, over a fake server and over a real local HTTP server; a deliberately broken delete rule fails three tests).
- The student app's debug build runs on a realme RMX3686 (Android 15). The QR on its screen, decoded from a screenshot, is accepted by the TypeScript `verifyScan`, so the phone's real Keystore signature, the DER-to-raw conversion and the compressed key all agree with the server code. The QR is replaced every 30 s.
- The scanner's debug build runs on the same phone with the public test key set: the camera read a signed QR from a PC monitor and the screen turned green with the student's details; an expired pass was rejected as EXPIRED. This was a one-phone test against a PC screen, not a phone-to-phone scan.
- The scanner's scan log works on the phone: the database was copied off the device after a test session and held the 3 exits that had been scanned (student, roll number, time, gate, guard, entry method, a UUID each), matching the "saved on this phone" count on screen.
- Sync works on the phone against a local stand-in for `scanner-sync`: the old version 1 log on the phone (10 rows) was upgraded to version 2 in place, all 10 rows went to the server in one request and arrived as 10 distinct ids, and the phone then held 0 rows. Offline, retry and error paths are covered by tests, not yet seen on the phone.
- **On the phone, against the real function:** with the phone disconnected from the PC, 3 scans were saved on it; after reconnecting, they reached `scanner-sync` (real handler, real SQL, Postgres engine) with their original ids and times, and the phone's log then held 0 rows. Scans made afterwards each arrived about 2 seconds after they were saved (3 more, all HTTP 200), and the phone again held 0 rows. The scanner screen showed the "Synced" pill. A scan for someone not on the roster (the demo pass) was kept by roll number with no student id, as designed.
- The redesigned screens of both apps were checked as rendered images (real fonts, light and dark, small phone with large text) and on the phone. They share `packages/campus_ui`.
- **The whole loop, on a PC against the real local server** (`apps/scanner_app/test/full_loop_integration_test.dart`): a scanner is activated with an admin-made code and receives its token, gate and the college key set; a student signs in with a code, enrols, is approved on the admin API and is issued a pass for a phone key; the scanner's own verify code accepts that pass with the key set it was given; the exit syncs with the scanner's token, the phone's log empties, and the exit appears in the admin exits table and in the CSV. The student app's own journey runs the same way (`apps/student_app/test/student_server_integration_test.dart`), including a QR from a different key being refused.
- The student app's journey is also covered through its screens with a fake server and a fake Keystore (124 tests): every wrong turn, the app killed and reopened at each stage, renewal 14 days before expiry, sign-out. Both debug APKs build with the new dependencies.
- Not verified: the new student screens (sign-in, details, waiting), the camera and gallery pickers, and scanner activation **on a phone**; scanning phone to phone, in sunlight or at gate distance; StrongBox versus TEE; any release build. The scanner has no revocation list (a revoked pass works until it expires), guard PIN, manual entry or keep-screen-awake yet. The scan log database is not encrypted.

Written but never run:

- `supabase/functions/scanner-sync/index.ts` and `scanner-activate/index.ts` (short Deno wiring; Deno is not installed here), `issue-credential/index.ts` (still a stub: its logic runs on the local server), the retention migration (needs `pg_cron`), `supabase/config.toml` through the CLI, and the row-level-security policies with real JWTs. Nothing has run on a Supabase project, and sign-in codes are shown in the app instead of emailed.
- **The local server signs passes with the public test key kv 2.** Anyone who reads the repository can forge a pass its scanners accept. A deployment needs its own key.

## Run the tests

```bash
# Dart (needs the Dart SDK 3.6 or newer)
dart pub get
cd packages/credential_core && dart test

# TypeScript
cd supabase/functions && npm install && npm test

# Flutter (each of apps/student_app, apps/scanner_app, packages/campus_ui)
flutter test

# The Dart apps against the real local server (start `npm run dev:server` first; see the top of each test file)
cd apps/scanner_app && DCID_SERVER_URL=http://127.0.0.1:8787 flutter test test/full_loop_integration_test.dart

# Regenerate the vectors; the output file must come out unchanged
node tools/gen-vectors/gen.mjs
```

## Choices in the spec worth confirming

These came from reading the PRD against what a real gate needs. Each is a starting value to test at the gate.

1. **Timestamp window is 45 s old / 10 s ahead, with a 30 s QR refresh.** The PRD says "a few seconds", but a QR stays on screen for the whole refresh interval, so a window shorter than that rejects a valid code. A forwarded QR therefore lives up to 45 s.
2. **Revocation is `[student id, revoked_at]`, and a credential is revoked if `iat <= revoked_at`.** One rule covers pause, reinstate and device change, so a new phone works as soon as its credential is issued.
3. **Branch is a short text code, not a number,** so adding a programme never needs an app update. This differs from the integer branch code suggested earlier; it costs about 7 bytes.
4. **The QR is 340 to 347 characters,** about QR version 12 at error-correction level L. If scanning in glare is slow in the pilot, the next saving is raw binary instead of base64url (about 25 percent smaller), which is a `DC2.` change.
5. **Manual entries have no credential.** The scanner logs the roll number the guard typed and the server resolves name, class and phone from the roster at export. The PRD's "unknown roster ID" red screen cannot be produced offline, because the scanner holds no roster; `UNKNOWN_KEY_VERSION` is the nearest equivalent.
6. **The Keystore signing key should not require biometrics,** because the QR re-signs every 30 s. The app lock gates the screen instead.

## Next steps

1. Try the new screens on a phone: sign-in, details with the camera, waiting, the pass, and scanner activation (`docs/DEMO.md`). Then a real phone-to-phone scan.
2. Deploy: wire `issue-credential/index.ts`, replace the local login with Supabase Auth, run `supabase start` and `supabase db reset` and fix what the migrations report, run `deno check` on the Edge Functions, set up custom SMTP, and generate a real college signing key.
3. The scanner's revocation list (G10), guard PIN (G1), manual entry (G8), keep-screen-awake, and an encrypted log.
4. The student app's app lock (S8), brightness boost (S10) and screenshot blocking; admin accounts and roles, and pause/revoke from the admin page.
