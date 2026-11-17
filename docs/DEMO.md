# Demo script, and what this prototype is and is not

What you can show, start to finish, on a laptop and one or two Android phones, with no Supabase, Docker or internet:

> A student signs up with their college email (`<roll number>@vnrvjiet.in`) and a 6-digit code, scans their ID card (the app reads name, branch and year off it), adds a phone number and a photo, and **gets their pass at once: there is no per-student approval**. The phone makes a key inside its secure hardware and the college signs a pass for that key. The guard's scanner, activated with a one-time code from the admin, scans the pass **offline**, saves the exit on the phone, and syncs it. The admin page shows the exit, and downloads the table as CSV.

## 1. Start the server (laptop)

```powershell
cd supabase\functions
npm install            # first time only
npm run dev:server
```

It prints the addresses and leaves a real Postgres (PGlite, Postgres 18) running in the same process. The same handlers and SQL that the Edge Functions use are behind every URL. Data is kept in `supabase\.dev-data` between runs; `$env:FRESH=1; npm run dev:server` starts from the seed again (5 students on the roster, scanners `SC-DEV` and `SC-NEW`).

Open the **admin website**: <http://127.0.0.1:8787/admin>. It **always asks for the admin password**, which the server prints in its window (`admin password:`). Choose your own with `$env:ADMIN_PASSWORD='something'` before starting it. Tabs: **Enrolments** (everyone who registered, with photos; it can reject one), **Roster** (add a student), **Scanners** (add one, make an activation code), **Exits** (search by name, roll number, branch or gate, filter by day, and download the CSV of exactly what you searched). *Sign out* is at the top. It refreshes itself every 4 seconds.

**Who can see what.** A student sees their own pass. A guard sees the scan result and **today's out pass list on the phone, view only** (the phone keeps the last two days and has no export or share button). Only the admin, signed in on the website, can search the full record and export the CSV, with the phone numbers. A scanner's token opens nothing on the admin website.

**Who may sign up.** Anyone whose email is their roll number at the college's domain, such as `25071a66j1@vnrvjiet.in`, and who proves it with the 6-digit code. A roll number looks like `25071A66J1` (five digits, a letter, four more) or a fresher's `ADM26-00317`; anything else (`stranger@vnrvjiet.in`, `25071a66j1@gmail.com`) is refused. The five students in `supabase/seed.sql` (`25071a0001` to `25071a0004`, and `adm26-00317`, a name with accents) have their name, branch and year on the roster; any other roll number signs up fresh and gives them from the ID card. Because there is no email service yet, the app shows the code: that is what stands in for "proves it".

## 2. Connect the phones

Over USB (the way everything here was tested):

```powershell
adb reverse tcp:8787 tcp:8787      # again whenever the cable is replugged
adb install -r apps\student_app\build\app\outputs\flutter-apk\app-debug.apk
adb install -r apps\scanner_app\build\app\outputs\flutter-apk\app-debug.apk
```

Both debug builds were made with `--dart-define=DCID_SERVER_URL=http://127.0.0.1:8787`, so the server address is already filled in. To rebuild: `flutter build apk --debug --dart-define=DCID_SERVER_URL=http://127.0.0.1:8787` in each app folder (the first build takes about 8 minutes).

To keep the USB tunnel alive (it drops silently when the cable or USB mode changes, and the apps then say *Can't reach the college server*), leave this running in a second window: `powershell -ExecutionPolicy Bypass -File tools\demo-tunnel.ps1`. It puts the tunnel back within two seconds.

Over Wi-Fi instead: `$env:HOST='0.0.0.0'; npm run dev:server` prints the laptop's address and an admin password; on each phone tap **Change** under the server line on the sign-in screen (student) or type it on the activation screen (scanner), e.g. `http://192.168.1.20:8787`. Allow the firewall prompt. (Not tried on a phone.)

## 3. The walk-through

1. **Student phone, sign in.** Open *Campus ID*. Type your own college email, for example `25071a66j1@vnrvjiet.in`, and tap **Send code**. A demo banner shows the code (there is no email service; it is also printed in the server window). Tap **Use it**, then **Sign in**.
2. **ID card.** Tap **Scan ID card** and photograph your college ID card (or **From gallery**). The text is read **on the phone** (Google ML Kit, no internet) and the card photo is deleted straight after: it never leaves the phone. Name, branch and year fill in; the year is also worked out from the roll number. Check them and correct anything misread. If the card shows a different roll number from the one you signed in with, the app refuses it.
3. **Photo and number.** Tap **Take photo** for a photo of your face, type a mobile number, tap **Get my pass**.
4. **The pass appears at once**: a QR that is replaced every 30 seconds, a LIVE badge, the countdown ring, your name, roll number, branch and year. The key it is bound to was made in the phone's Keystore and never leaves it. On the admin page the enrolment is listed as *approved* (with a *Reject* button for the exceptional case; a rejected student who sends a new photo waits for an admin).
5. **Scanner phone, activation.** Open *Campus Gate* and allow the camera. The pill at the bottom of the scan screen says **Activate** (a debug build already trusts the public test keys, so it can scan, but it cannot sync). On the admin page, **Scanners > New activation code** for `SC-NEW`; tap the pill and type the code on the scanner (it works once, for 15 minutes). The scanner now has its own token, its gate name ("North gate") and the college keys, and the pill changes to *Synced*.
6. **Scan, in the right mode.** The scanner has a switch at the top: **Verify** (the default) only checks a pass and records nothing; **Out pass** records each valid pass as an exit. Scan first in Verify: green, *VERIFY ONLY · NOT RECORDED*, the saved count stays 0. Then tap **Out pass** (it turns amber) and scan again. Point the scanner at the student's phone: green with the student's details, a pulse of haptics, the *saved on this phone* count goes up, and about 2 seconds later the pill says *Synced*.
7. **Today's out pass list, on the guard's phone.** Tap the **"Saved on this phone"** panel at the bottom of the scan screen. Every student let through today is listed, newest first, with name, roll number, branch, year and time. It is **view only**: there is no export or share button, and the phone drops anything older than two days. The list is not emptied when the exits sync, unlike the queue behind the "Saved on this phone" count.
8. **Admin website, Exits.** Sign in. The same exits appear, matched to the student, with gate, scanner and time in Indian time, and **with the student's phone number**, which the pass does not carry. Search for a name, pick a From/To day, and **Download CSV of this search** gives a file that opens in Excel with the accents intact (named for the days, e.g. `outpass-2026-10-28-to-now.csv`). With nothing typed, the button downloads everything.

Things worth showing next, each one quick:

- **A screenshot does not work.** Wait a minute and scan a screenshot of the QR: red, *Clock mismatch*.
- **Offline.** Put the scanner phone in airplane mode and scan: green, saved. Turn it back on: the pill goes from *Offline* to *Synced* and the exits arrive with their original times.
- **Someone else's card.** Scan a classmate's card: the app says the card is for another roll number and uses nothing from it.
- **The pass survives.** Force-stop the student app, switch off mobile data, open it: the pass is there at once.
- **A rejected photo.** Tap **Reject** on the admin page for a student: the phone returns to the details screen and says the photo was not accepted; the new photo then waits for an admin.
- **Sign out** (the menu at the top right of the pass) removes the login, the pass and the key from the phone. Signing in again gets a new pass for a new key.

### With only one phone

The scanner cannot scan its own screen. Open <http://127.0.0.1:8787/_dev/test-pass> on the laptop: it shows a signed QR for a roster student, renewed every 5 seconds, and the scanner phone can scan the laptop screen. That pass is made by the server with the **public test keys**, not by a student's phone, so it demonstrates the scanner, the sync and the admin table, not the student app. Then show the student app's own screen on its own (step 1 to 4), and scan with a second phone if one can be borrowed (install the scanner APK on it with `adb install`, or send the file).

## 4. What is real, and what is not

Say these out loud rather than have them found.

**Real, and tested:**

- The credential format: ES256 college signature, a device signature over a fresh timestamp every 30 seconds, offline verification, a 45-second window. Three independent implementations (Node, TypeScript, Dart) agree on shared test vectors.
- The device key lives in the Android Keystore (StrongBox or TEE where the phone has it), and the pass is bound to it: a copy of the credential without the key is refused.
- The server logic (sign-in codes, enrolment, issuing, activation, sync, admin) runs on a real Postgres engine in tests: **305 server tests, 150 student app tests, 250 scanner tests**, plus tests that run the Dart apps' code against the real local server (`apps/scanner_app/test/full_loop_integration_test.dart` runs the whole loop above in one go).
- The scanner never loses an exit: it is written to disk before the screen turns green, and deleted from the phone only when the server names it in its reply.

**Not real yet, honestly:**

- **No real email.** The code is shown in the app and the server window, so while the server is in demo mode, **anyone who can reach it can sign in as any roll number**. The "proof" is the mailbox, and no mail is sent yet. With `DEMO_OTP=0` the code appears only in the server window.
- **The ID card is a convenience, not a check.** The phone reads the card and the server takes the name, branch and year the app sends. The server cannot see the card, so it does not verify them; the roll number on the card is only compared with the account's by the app. Duplicate photos are flagged on the admin page, not blocked.
- **Not on Supabase.** Everything runs on this laptop. The Edge Function wiring files (`index.ts`) were never run (Deno is not installed here), the row-level-security policies were never tried with real logins, and nothing has been deployed.
- **The college signing key is a public test key** from the repository: anyone who reads the repository can forge a pass that this server's scanners accept. It must be replaced (a generated key, then a cloud KMS) before any real use.
- **The admin website is a prototype.** It has a login (one shared password, sessions kept in memory, five wrong tries lock it for a minute), but no separate admin accounts, roles, audit trail, or pause and revoke buttons. It lists enrolments and can reject one; it approves nothing by default.
- **Revocation is not enforced at the gate.** The server records revocations (a second phone replaces the first), but the scanner does not download the revocation list yet, so a revoked pass keeps working until it expires (up to 180 days).
- **The guard's list on the phone has no phone numbers** (the pass does not carry them), is not encrypted, keeps two days, and belongs to that one phone: two gates mean two lists, joined on the admin website.
- **The scanner has no guard login or PIN** (every exit is logged to the placeholder guard `G-DEV`), no manual entry for a student without a phone, no keep-screen-awake, and its log is not encrypted on the phone.
- **The student app has no app lock, no brightness boost, no screenshot blocking.** The ID card reader is tuned to the typical layout (header, `Name`, `Roll No`, `Branch`) and was tested on sample text and one mock card, not on every card design: always check what it filled in.
- **What has been seen on a phone:** the pass screen and Keystore signer, the scanner's scan, log and sync, the sign-in and registration screens with your roll number, the camera and photo flow, and the ID card reader. **What has only run on the laptop:** scanner activation on the phone. Scanning phone to phone, in sunlight, and at gate distance have not been tried.

## 5. If something goes wrong on the day

| Sign | Likely cause | Do this |
|---|---|---|
| The app says *Can't reach the college server* | The USB tunnel died (it dies when the cable is replugged) or the server stopped | `adb reverse tcp:8787 tcp:8787` again; check the server window is still running |
| The server window says the port is in use | An older server is still running | Close it, or `$env:PORT=8788; npm run dev:server` and use that port in both `adb reverse` and the apps |
| The ID card gives a wrong name | The card layout is not what the reader expects | Correct it in the Name field before tapping **Get my pass** |
| Sign-in says *Please wait 30 seconds* | A code was asked for less than 30 seconds ago | Wait, then ask again (or use the code already shown) |
| *Too many wrong tries* | Five wrong codes | Go back and ask for a new code |
| The camera does not open on the details screen | Camera permission denied | Allow it in Android settings, or use *Choose from gallery* |
| The admin website says *That password is not right* | The password is the one the server printed when it started, or the `ADMIN_PASSWORD` you set | Look for `admin password:` in the server window; restarting without `ADMIN_PASSWORD` makes a new one |
| The scanner says *Not authorised* | The scanner was activated again somewhere else (a new code replaces the old token), or the server data was reset with `FRESH=1` | Make a new activation code and activate again |
| Nothing makes sense | Start clean | Stop the server; `$env:FRESH=1; npm run dev:server`; in each app's Android settings choose *Clear storage* |
