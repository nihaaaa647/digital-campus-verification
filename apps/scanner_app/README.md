# scanner_app

The guard's Android scanner: activation, continuous QR scanning, offline verification, a local log and sync.

## Status

Activation, scan, verify, the green/red result screen (G3, G4, G5), the same-student debounce (G6), the local scan log (G7) and sync (G9, with the server-clock offset of G14) are written. `flutter analyze` is clean and 250 tests pass (2 more are skipped unless a local server is running) on Flutter 3.47.8.

Verified on a realme RMX3686 (Android 15): the camera read a signed QR shown on a PC monitor and the screen turned green; the log database copied off the phone held the 3 exits scanned. Sync was run on the phone against a local stand-in server (see "Sync" below), and the Dart sync code was run against the real `scanner-sync` function and a real Postgres (see `supabase/README.md`). On the phone against that real function: scans saved while the phone had no connection were delivered after it reconnected, with their original ids, and later scans arrived about 2 seconds after they were saved; the phone's log emptied each time.

**Activation** is written and was run on a PC against the real local server (`test/full_loop_integration_test.dart`): the guard types the server address and a one-time code from the admin page, and the scanner stores its own token, its gate name and the college key set. That test also takes a pass issued by the real server, has the scanner accept it with the key set it was given, syncs the exit, and finds it on the admin page and in the CSV. Activation has not yet been tried on a phone.

Not built yet: deploying to a real Supabase project (everything has only run on a laptop), revocation list (G10), refreshing the college keys from the sync reply, guard PIN (G1), manual entry (G8), keeping the screen awake, and a sound on result. The log database is not encrypted. Nothing has been tried in sunlight, at gate distance, or with two phones.

## What it does

| File | Job |
|---|---|
| `lib/src/camera_view.dart` | The only file that touches the camera plugin (`mobile_scanner`, bundled ML Kit model, so it needs no network). Torch button, camera-permission error screen. |
| `lib/src/gate_controller.dart` | `onCode` verifies each code with `verifyScan` from `credential_core`, saves the exit, holds one result at a time (green 3 s, red 6 s, tap to skip), and ignores a code that is still in front of the camera. |
| `lib/src/gate_result.dart` | The red-screen words. Titles come from `docs/credential-spec.md` section 9; a test reads the spec table and fails if they drift. |
| `lib/src/scan_log.dart` | `ScanLog` and `SqliteScanLog` (`sqlite3` package, WAL, full sync on every commit). The table repeats the server's `scans` constraints. `append` returns only after the row is on disk. Schema version 2 also keeps the sync state (server-clock offset, last sync time); version 1 databases are upgraded in place. |
| `lib/src/sync_client.dart` | One round trip to `scanner-sync`, exactly as documented in `supabase/functions/scanner-sync/index.ts`. Maps every failure to a `SyncFailure`; deletes nothing. |
| `lib/src/sync_service.dart` | Sends the saved rows in batches, deletes only the rows the server names, retries with backoff, updates the clock offset. |
| `lib/src/scan_screen.dart`, `scan_overlay.dart`, `result_overlay.dart` | Camera with a dimmed framing window, brackets and sweep line; top bar, saved-count panel with the sync status pill; full-screen green/red result card with a countdown bar, icon and words (never colour alone); haptics: one pulse for green, two for red. A compact layout is used on short screens or large system text. |
| `lib/src/key_set.dart`, `assets/keys/dev-keyset.json` | Where the trusted college keys come from. |

**Dev keys.** The bundled key set is the PUBLIC test key set from `spec/test-vectors/v1.json` (kv 1 previous, kv 2 current). Debug builds load it and show an amber DEV KEYS tag. A release build has no keys and refuses to scan unless built with `--dart-define=DCID_DEV_KEYS=true`, so a scanner that trusts every copy of the test vectors can't be shipped by accident. A test fails if the asset differs from the vectors.

**Saving (G7).** A valid scan is written to the log first; only then does the green screen appear. If the write fails, the guard sees a red NOT SAVED screen with the student's name and what to do, never green. A rejected pass is not an exit and is not logged. The scanner will not start if the log cannot be opened. The gate on each row is the activated scanner's gate; the guard is the placeholder `G-DEV` (`devGateContext`) until guard login exists, and the server refuses a guard it does not know. Android backup is off for the app.

**Debounce rules (G6).** The exact same QR text is ignored for 55 s after it was accepted (it can only pass the time window for 45 s plus 10 s of allowed clock lead). A refreshed QR from the same student is ignored for 5 s. A rejected code is ignored for 5 s so one bad code shows red once, not on every camera frame. A student who exits and comes straight back with the same unrefreshed QR is silently ignored for up to a minute; decide at the pilot whether that needs an "already scanned" screen. Seen in testing: one student's code left in front of the camera produced 3 rows in 26 seconds (about every 7 s, as the code refreshed past the 5 s window). That is fine for a student who walks through, but consider a longer same-student window if gates see people lingering.

**Debug log.** Debug builds print one line per verified code (verdict, length, first 12 characters), visible with `adb logcat flutter:I *:S`. It never prints a whole code.

## Modes: Verify and Out pass

The scanner has two modes, chosen with the switch at the top of the scan screen (`GateMode` in `gate_result.dart`, `GateController.setMode`):

| | **Verify** (the default) | **Out pass** |
|---|---|---|
| A valid pass | green, *VERIFY ONLY · NOT RECORDED*, "Checked HH:MM:SS · not recorded" | green, *OUT PASS RECORDED*, "Saved HH:MM:SS" |
| Written to the log, listed, counted, synced | **no** (a broken log does not matter either) | yes, before the green screen (a failed write is the red "not saved" screen) |
| Hint under the frame | "Point at the student's QR code" | "Out pass mode · each scan is recorded" |
| A bad pass | red | red |

The scanner always starts in Verify, so nothing is recorded unless a guard asks for it. Switching dismisses any result on screen and forgets what was just seen, so a pass that was only verified can be recorded straight away by scanning it again in Out pass mode. The mode is not remembered across restarts. Tests: `test/gate_modes_test.dart` (verify writes nothing, even to a log that would throw; switching; the on-screen words; small phone with large text) and a deliberately broken "verify records" makes six of them fail.

## Out pass list

Every student let through is also written to a short **list** on the phone (`outpass_register` table, schema version 3), in the same transaction as the sync queue row, so a green screen means both are on disk. Unlike the queue, it is not emptied when the server confirms an exit, so the guard has a logbook for the shift. It holds what the pass said about the student (name, roll number, branch, year) plus time, gate, guard and entry method; those details are **not** sent to the server, which has the roster. A manual entry has no details and is queued but not listed. Rows older than two days are deleted as new exits come in.

The **"Saved on this phone"** panel at the bottom of the scan screen opens `OutpassScreen`: today's exits, newest first, with a count. **It is view only.** A guard cannot export, share or copy it out as a file: the app has no CSV code and no share plugin, and a test fails if either comes back. Searching the full record and downloading the CSV belong to the admin website (`/admin`, behind a login that a scanner's token does not open). Tested: the list and queue written together and kept after sync, the two-day limit, a version 2 log upgraded in place, the screen, and a whole-app test from a scan to the list.

## Sync (G9, G14)

The scanner sends its saved rows to `scanner-sync` and deletes the rows the server confirms. The request and reply are the ones documented at the top of `supabase/functions/scanner-sync/index.ts`: `POST {scans: [...], visitors: []}` with `Authorization: Bearer <token>`, answered by `{accepted_scan_ids: [...], server_time: ...}`.

- **A row is deleted only when the server names its `scan_id` in `accepted_scan_ids`**, and only if that id was in the batch just sent. A lost reply, a timeout or a half-finished batch just means the same rows (same ids) are sent again; the server ignores repeats (`on conflict do nothing`). Tests break this rule on purpose and fail.
- **When it runs:** about 2 seconds after each saved scan (a burst goes in one request), every 5 minutes while all is well (to keep the clock fresh, even with nothing to send), when the guard taps the status pill, and at startup. After a failure it retries after 30 s, 1 min, 2 min... up to 15 min; a wrong token or a disabled scanner waits the full 15 min.
- **Batches of 100**, oldest first, until the log is empty. If the server accepts none of a batch, the scanner stops rather than spin and shows "Sync problem".
- **Clock (G14):** each reply's `server_time` gives the offset between the server and the phone (corrected for the time the request took). It is stored in the log database and added to the phone clock whenever a pass is verified or a scan is stamped.
- **Status pill** in the bottom panel: Sync off (no address in this build), Syncing, Synced HH:MM, Offline (retrying by itself), Not authorised (401), Disabled (403), Sync problem. Tap it to sync now.
- **Not read yet:** `keyset`, `revocation_list` and `guards` in the reply (G10 and key refresh).
- **Known limitation:** a row the server refuses stays in the log and is retried forever. The real function refuses a row for a `guard_id` it does not know (`unknown_guard`), which is what the placeholder guard `G-DEV` hits on any server that has not been seeded with it; it lists such rows in `rejected` in its reply, which the scanner does not read yet. Decide later whether to park them and show the guard what is stuck.

## Activation

A scanner phone is made a scanner by an admin, not by a build. On the admin page (Scanners tab) press **New activation code** for a scanner; the code works once, for 15 minutes. On the phone, the scanner shows the activation screen: type the server's address (prefilled when the build has `--dart-define=DCID_SERVER_URL=...`) and the code. The server answers with the scanner's own token, its gate and the college key set. The scanner keeps the token and keys in `flutter_secure_storage` and the identity beside them, and from then on syncs with that token. Activating an already activated scanner replaces its token.

- The activation screen can be left with "Not now" when the scanner already holds keys (debug builds hold the public test keys), and is reached again from the scan screen.
- If the keys cannot be saved, activation does not half-happen: the identity is only saved after the keys, and rolled back if that fails.
- Release builds need an `https://` address; debug builds also take `http://` (a dev server reached with `adb reverse tcp:8787 tcp:8787`).

For development only, a build can skip activation and sync as a fixed scanner: `--dart-define=DCID_SYNC_URL=.../functions/v1/scanner-sync --dart-define=DCID_SYNC_TOKEN=dev-token`. Without any of this the scanner keeps every scan on the phone and the pill says "Sync off".

## Run

Needs Flutter 3.27 or newer and the Android SDK including NDK 28.2.13676358 (see the student app README if Gradle says "Package ndk not found"). From this folder:

```bash
flutter pub get
flutter test
flutter run
```

The app asks for camera permission on first launch. If `android/` is ever lost, `flutter create --platforms android --org app.dcid --project-name scanner_app .` regenerates it without touching `lib/` or `pubspec.yaml`; then set `minSdk = 26` in `android/app/build.gradle.kts`, add `<uses-permission android:name="android.permission.CAMERA" />` and `INTERNET` to `AndroidManifest.xml`, set the app label to "Campus Gate", turn `allowBackup` off, and add `android:usesCleartextTraffic="true"` to the debug manifest only.

## What to build next, in order

| Req | Work | Library or note |
|---|---|---|
| server | Deploy the functions and try the phone over the internet | written and tested against a local Postgres (`supabase/README.md`); needs a Supabase project, secrets, and HTTPS |
| G10 | Verify and store the revocation list | `verifyRevocationList`; replace the stored list only if `seq` is higher; warn when its `iat` is over 24 h old. `GateController` already takes `revoked`, and the sync reply already carries the list. |
| keys | Replace the bundled test keys | take the key set from the sync reply (spec section 8), keep current and previous |
| G1 | Guard PIN, offline | PBKDF2 hashes arrive on sync; verify locally |
| G8 | Manual entry | type a roll number, log it with `entry_method = manual`; the server resolves the name |
| G7 follow-up | Encrypt the log at rest | SQLite3MultipleCiphers through the `sqlite3` package's hook options (see its `doc/hook.md`) |
| keep awake | Screen must not sleep at the gate | `wakelock_plus` |

## Testing with one phone

`flutter test` covers the logic and screens, including sync against a fake server and against a real local HTTP server. To see the camera path with a single phone, show signed test QR codes on a PC screen and point the phone at them: the signing needs only the public test keys. To see activation and sync on the phone, run the local server on the PC (`cd supabase/functions && npm run dev:server`), forward its port with `adb reverse tcp:8787 tcp:8787`, build with `--dart-define=DCID_SERVER_URL=http://127.0.0.1:8787`, and activate with a code from the admin page (`docs/DEMO.md`). The pages and servers used while building this lived in a scratchpad and are not part of the repository.
