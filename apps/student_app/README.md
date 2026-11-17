# student_app

The student phone app: sign-up and login, enrolment, the rotating QR pass.

## Status

**Sign in with the college email (`<roll number>@vnrvjiet.in`) and a 6-digit code, scan the ID card (name, branch and year are read on the phone with Google ML Kit, offline, and the card photo is deleted straight after), add a phone number and a photo, and get a pass signed by the college for this phone's Keystore key at once: there is no per-student approval** (S1, S2, S3, S5, S6, S9). Seen on a realme RMX3686 (Android 15): sign-in with a real roll number, the ID card reader, the camera, the pass. The reader first took the college's own name from the card header ("Valluripally Nageswara Rao") for the student's; fixed and covered by tests. `flutter analyze` is clean; 150 tests pass on Flutter 3.47.8 (3 more run against a real local server when one is given, see below).

What the tests cover:

- `test/home_controller_test.dart` (49): every step of the journey and every way it can go wrong, with the college server and the phone's key store faked: wrong code, five wrong tries, not on the roster, no connection, a rejected photo that is sent again, approval taken back, the app closed and opened at each stage, a login the server forgot, a pass issued to a key the phone no longer has, renewal when 14 days are left, an expired pass replaced on its own, sign-out removing the login, the pass and the key. Breaking four of these rules on purpose (renewal, key removal on sign-out, session clearing, the double-tap guard) makes tests fail.
- `test/onboarding_flow_test.dart` (16): the same journey through the real screens, ending in a QR that the scanner's own `verifyScan` accepts and that names this phone's key; small phone with large text, dark theme, the sign-out menu.
- `test/student_api_test.dart` (25): each server answer and status code, and a reply that is not the server's.
- `test/student_server_integration_test.dart` (3, skipped unless `DCID_STUDENT_SERVER_URL` is set): the same Dart code against the **real local server** (real handlers, SQL and Postgres): sign in, enrol, admin approval, issue, a QR accepted against the college key set, a QR from another key refused, a second phone replacing the first, sign-out ending the login. Run it with the server from `docs/DEMO.md`: `DCID_STUDENT_SERVER_URL=http://127.0.0.1:8790 flutter test test/student_server_integration_test.dart`.
- The older pass tests (34): the Keystore signer against a fake of the Kotlin channel, the 30-second refresh, expiry, clock offset.

**Not yet seen on a phone:** the sign-in and enrolment screens, the camera (`image_picker`) and the gallery picker, and the new server calls over `adb reverse`. The pass screen and the Keystore signer were run on a realme RMX3686 (Android 15) before this work: the QR was replaced every 30 s and each QR passed the server-side `verifyScan` with the phone's real Keystore key.

`minSdk` is 26 (the PRD requires Android 8 or later), `allowBackup` is off so a restored backup cannot carry a credential to another phone, and only the debug manifest allows plain `http://` (for the laptop server).

## How it fits together

| File | Job |
|---|---|
| `android/.../KeystoreChannel.kt` | One P-256 key in the Android Keystore (StrongBox if the phone has it, else the TEE), no user authentication. Calls `key`, `sign`, `deleteKey`. `sign` never creates a key. |
| `lib/src/keystore_signer.dart` | `KeystoreSigner implements DeviceSigner`. Converts the X.509 key to the 33-byte compressed `dpk` and the DER signature to raw `r \|\| s`. |
| `lib/src/pass_store.dart` | `StoredPass` (the `DK1.` text plus the server-time offset). `SecurePassStore` uses `flutter_secure_storage`. |
| `lib/src/pass_controller.dart` | `openPass` checks the stored credential against this phone's key and the clock. `PassController` re-signs every 30 s from one 1-second timer, withdraws the QR when it cannot renew it or the pass expires, and retries signing every second after a failure. |
| `lib/src/pass_screen.dart` | A card with the QR as the hero (black on white, level L, 14 dp quiet zone), a countdown ring, then avatar, name, roll, branch, year, pass type and expiry; a pulsing LIVE badge (a screenshot does not pulse); clock warning; light and dark theme from `packages/campus_ui`. |
| `lib/src/home_controller.dart` | `HomeController`: the whole journey as a state machine (`Stage`: starting, signedOut, details, pending, activating, pass, offline). It reads what the phone holds and what the server says, so the app can be killed at any point and reopen on the right screen. All rules and all server calls are here; the screens only show the stage. |
| `lib/src/student_api.dart` | `StudentApi`: `auth-request-otp`, `auth-verify-otp`, `auth-sign-out`, `enrol`, `enrolment-status`, `issue-credential`. Every call returns or throws an `ApiException` with a reason; a 200 that is not the server's reply is refused. |
| `lib/src/session_store.dart` | The login (token and who it is for) and the chosen server address, in encrypted storage beside the pass. |
| `lib/src/onboarding_screens.dart` | Sign-in (email, then code; the code is shown in a demo banner while the server has no email service), details (phone and photo), waiting (checks every 4 s), getting the pass, offline with retry. |
| `lib/src/photo_source.dart` | `image_picker` behind a small interface: the front camera or the gallery, shrunk to a 900 px JPEG. |
| `lib/src/server_address.dart` | Turns what is typed into the server address; `https` only unless the build allows `http`. |
| `lib/src/demo_issuer.dart` | Debug builds only: signs a made-up student with the **public test** college key (kv 1 from the test vectors), so the screen works before `issue-credential` exists. Release builds never reach it. |

**Debug builds only:** "Create demo pass" on the sign-in screen makes a pass with no server and no login (the public test key kv 1), for looking at the pass screen alone.

**The pass renews itself.** When the app opens and the pass has under 14 days left, it asks the server for a fresh one for the same key (a failure changes nothing: the old pass works until it expires). An expired pass is replaced the same way if the login and approval still stand; otherwise the sign-in screen says why. Signing out removes the login, the pass and the phone's key.

## Run

Needs Flutter 3.27 or newer and the Android SDK, including NDK 28.2.13676358 (`flutter doctor` shows what is missing). If Gradle fails with "Package ndk not found", install it by hand: the SDK manager now names packages with a slash, so `sdkmanager "ndk/28.2.13676358"`. From this folder:

```bash
flutter pub get
flutter test
flutter run --dart-define=DCID_SERVER_URL=http://127.0.0.1:8787     # the local server over adb reverse (docs/DEMO.md)
```

Without `DCID_SERVER_URL` the sign-in screen asks for the server address (there is a "Change" link on it either way).

The application id is `app.dcid.student_app`; change `--org` before the first Play Console upload if the college wants its own namespace. If `android/` is ever lost, `flutter create --platforms android --org app.dcid --project-name student_app .` regenerates it without touching `lib/` or `pubspec.yaml`; then set `minSdk = 26` in `android/app/build.gradle.kts`.

## What to build, in order

| Req | Work | Library or note |
|---|---|---|
| S5 | ~~Keystore signer~~ | **done**, run on a phone |
| S6 | ~~Pass screen~~ | **done**; still to do: brightness boost (S10), block screenshots, app lock (S8) |
| S1 | ~~Email OTP sign-up and login~~ | **done against the local server** (`student_auth.ts`); on Supabase this becomes `supabase_flutter` email OTP, and `StudentApi` is the one file to change |
| S3 | ~~Phone and photo at enrolment~~ | **done** (the photo goes to the server; the PRD kept ID-card images on the phone, and the card OCR below is not built) |
| S9 | ~~Credential refresh~~ | **done**: at app open, 14 days before expiry |
| S8 | App lock | `local_auth`; gate the QR and ID screens, not the Keystore key |
| S7 | ID view | large photo, name, roll, branch, year, pass type, ticking clock |
| S2 | ~~Card OCR~~ | **done**: `lib/src/id_card.dart` (`parseIdCard`, tested on card layouts) with `google_mlkit_text_recognition`; the card photo stays on the phone and is deleted after reading |
| S10 | Brightness boost | `screen_brightness`, `wakelock_plus` |
| privacy | Block screenshots on the QR and ID screens | `FLAG_SECURE` on those screens only |
| trust | Verify the college signature on the issued pass with a bundled key set before saving it | the app trusts the server's reply (over TLS) today |
