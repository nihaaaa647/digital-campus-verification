# START HERE: what to do for the demo

Everything is already set up on this laptop and your phone. Do **Check** first (2 minutes), then **Demo** (5 minutes).

## Check (before you start)

1. **Server is running.** Open <http://127.0.0.1:8787/admin>. You should see a sign-in page.
   If it does not open, start the server in PowerShell:
   ```powershell
   cd C:\Users\Niharika\DT_project\supabase\functions
   $env:ADMIN_PASSWORD='admin-demo-2026'
   npm run dev:server
   ```
   Leave that window open. (It prints `admin password:` when it starts.)
2. **Phone is connected by USB**, unlocked, USB mode *File transfer*.
3. **Tunnel is up** (lets the phone reach the laptop). In a second PowerShell window:
   ```powershell
   cd C:\Users\Niharika\DT_project
   powershell -ExecutionPolicy Bypass -File tools\demo-tunnel.ps1
   ```
   Leave it open: it fixes the tunnel by itself if the cable glitches.
   Manual fix if an app says *Can't reach the college server*:
   `& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:8787 tcp:8787`
4. **Sign in to the admin website once** in the browser you will present with: <http://127.0.0.1:8787/admin>, password `admin-demo-2026`. (The scanner test page below needs this.)

## Demo (in this order)

### 1. Student registers and gets a pass (phone: *Campus ID* app)
- It is already on the **"One more step"** screen, signed in as roll number **25071A66J1**.
  (If it shows a pass or the sign-in page instead: menu ⋮ → *Sign out*, then type `25071a66j1@vnrvjiet.in`, tap *Send code*, tap **Use it**, tap *Sign in*.)
- Tap **Scan ID card** and photograph your college ID card. Name, branch and year fill in. **Check the Name** and fix it if wrong.
- Tap **Take photo** (face; switch to the front camera in the camera app if needed) and tap the tick.
- Type your mobile number. Tap **Get my pass**.
- The pass appears **at once**: QR code, LIVE badge, countdown. Point out: *no admin approved this*; the email `roll-number@vnrvjiet.in` plus the code proved who you are.

### 2. Guard scans at the gate (phone: *Campus Gate* app)
The scanner has **two modes**, switched at the top of the screen:
- **Verify** (the default): checks the pass only. Green or red, **nothing is recorded**. Use it to check who someone is.
- **Out pass**: every valid pass is **recorded** as an exit (saved, listed, synced). The guard taps **Out pass** at the top when students are going out, and **Verify** again afterwards.

Steps (one phone: the scanner scans a test pass shown on the laptop):
- On the laptop open <http://127.0.0.1:8787/_dev/test-pass?roll=25071A0002> (Anita Rao).
- Open *Campus Gate*. Point it at the laptop screen in **Verify** mode: **green**, with a grey line *"VERIFY ONLY · NOT RECORDED"*. The saved count stays 0 and the admin site shows nothing.
- Tap **Out pass** at the top (it turns amber), scan again: green with *"OUT PASS RECORDED"*, the saved count goes to 1, and within seconds the pill says **Synced**.
- Tap the **"Saved on this phone"** panel at the bottom: today's list, **view only, no export button**. Guards cannot take student data out.

(If you have a second phone: install the student app there and scan its QR instead.)

### 3. Admin checks and exports (laptop: browser)
- <http://127.0.0.1:8787/admin> → **Exits** tab. The scan is there, with the student's **phone number**.
- Type a name or pick a day, tap **Search**, then **Download CSV of this search**. Open it in Excel.
- Show *Sign out*, then reload the page: it asks for the password again. Only the admin can export.

## If something goes wrong

| What you see | Do this |
|---|---|
| App: *Can't reach the college server* | Run the manual tunnel fix above |
| Scanner pill says **Activate** or **Not authorised** | Admin site → **Scanners** → *New activation code* for `SC-NEW` → on the phone tap **Activate**, type the code, tap *Activate scanner* |
| Scanner does not turn green | The QR must be fresh: reload the test-pass page. Hold the phone steady 20 to 30 cm from the screen, screen brightness up |
| Student app shows an old pass | Menu ⋮ → *Sign out*, then sign in again |
| ID card reads the wrong name | Type the right name in the Name box |
| Camera will not open | Tap *From gallery* instead |
| Admin password forgotten | `admin-demo-2026` (the server printed it when it started) |
| Everything is a mess | Close the server window, run the server again with `$env:FRESH=1;` before `npm run dev:server`, then re-activate the scanner (above) and sign the student app out and in |

## What to say if asked

- **How does the scanner know a QR is real with no internet?** The QR carries the student's details, the college's digital signature on them, and a fresh timestamp signed by the student's phone. The scanner has the college's public key and checks the signatures with maths. A screenshot fails after under a minute; a copied pass fails because only that phone can sign.
- **Why two modes?** Checking a pass and letting someone out are different jobs. Verify never writes anything, so a guard can check as many passes as they like without making exits. Out pass is a deliberate switch.
- **Why can't a guard export the data?** The guard app has no export; the full record and CSV are on the admin website, behind a login that a scanner cannot use.
- **Why no admin approval?** The student proves they own their college email (`roll-number@vnrvjiet.in`) with a one-time code, so approval is automatic. An admin can still reject someone.

## Be honest about these (they are prototype limits)

- No real email is sent yet: the sign-in code is shown in the app.
- It runs on this laptop, not on a cloud server (no Supabase deployment).
- The college signing key is a public test key. A real launch needs its own.
- A cancelled pass still works until it expires: the scanner does not download the cancelled list yet.
- One shared admin password, no separate admin accounts; the guard's phone list is not encrypted.

More detail: `docs/DEMO.md`.
