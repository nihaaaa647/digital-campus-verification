// The whole backend on a laptop, for demonstrating the prototype without Supabase, Docker or the internet.
// It runs the same handlers and SQL as the Edge Functions, on a real Postgres (PGlite) in this process, and
// adds a small admin page. Login codes are shown on this screen and in the app, because there is no email.
//
//   npm run dev:server                    http://127.0.0.1:8787     data kept in supabase/.dev-data
//   HOST=0.0.0.0 npm run dev:server       reachable from phones on the same Wi-Fi
//   FRESH=1 npm run dev:server            starts from the seed again, forgetting everything
//   PORT=9000, ADMIN_PASSWORD=..., DEMO_OTP=0 (do not show codes in replies), MEMORY=1 (keep nothing on disk)
//
// The admin website (/admin) always asks for the admin password, which is printed below when the server starts
// (choose it with ADMIN_PASSWORD). Everything that can read or export student data is behind it.
//
// Phones: with the USB cable, `adb reverse tcp:8787 tcp:8787` and use http://127.0.0.1:8787; on Wi-Fi use the
// address printed below. Admin page: /admin. Scanner: token `dev-token` (SC-DEV), or activate SC-NEW with a
// code from the admin page.
//
// Routes (all under /functions/v1/): auth-request-otp, auth-verify-otp, auth-sign-out, enrol, enrolment-status,
// issue-credential, scanner-activate, scanner-sync. Development routes: /admin, /admin/api/*, /_dev/*.

import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { networkInterfaces } from 'node:os';

import QRCode from 'qrcode';
import { hexToBytes } from '@noble/hashes/utils';
import type { KeySetDocument } from '../_shared/credential.ts';
import { handleEnrol, handleEnrolmentStatus } from '../_shared/enrolment.ts';
import { handleIssueCredential } from '../_shared/issue_credential.ts';
import { PgSyncStore } from '../_shared/pg_sync_store.ts';
import { PgStudentStore } from '../_shared/pg_student_store.ts';
import { handleScannerActivate, issueActivationCode } from '../_shared/scanner_activate.ts';
import { handleScannerSync } from '../_shared/scanner_sync.ts';
import { handleRequestOtp, handleSignOut, handleVerifyOtp } from '../_shared/student_auth.ts';
import { createAdminAuth } from './admin_auth.ts';
import { handleAdmin } from './admin.ts';
import { devCollegeSigner } from './dev_signer.ts';
import { createLocalDatabase, pgliteDb } from './local_db.ts';
import { testPassQr } from './test_pass.ts';

declare const process: { env: Record<string, string | undefined>; on(signal: string, handler: () => void): void; exit(code?: number): never };

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? '127.0.0.1';
const loopback = host === '127.0.0.1' || host === 'localhost' || host === '::1';
const exposeOtp = process.env.DEMO_OTP !== '0';

// The admin website reads and exports student data and hands out scanner codes, so it always needs a password,
// on this laptop as much as on the network.
const adminPassword = process.env.ADMIN_PASSWORD ?? randomBytes(4).toString('hex');
const adminAuth = createAdminAuth({ password: adminPassword });

const dataDir = new URL('../../.dev-data/', import.meta.url);
const dataPath = decodeURIComponent(dataDir.pathname).replace(/^\/([A-Za-z]:)/, '$1');
const inMemory = process.env.MEMORY === '1';
if (process.env.FRESH === '1' && existsSync(dataPath)) rmSync(dataPath, { recursive: true, force: true });

async function openDatabase() {
  if (inMemory) return await createLocalDatabase();
  try {
    return await createLocalDatabase({ dataDir: dataPath });
  } catch (error) {
    // A database damaged by a hard stop is put aside, not deleted, and a fresh one is made.
    const aside = `${dataPath.replace(/[\\/]$/, '')}-damaged-${Date.now()}`;
    console.error(`The saved data could not be opened (${error instanceof Error ? error.message : error}). Moved to ${aside}; starting fresh.`);
    renameSync(dataPath, aside);
    return await createLocalDatabase({ dataDir: dataPath });
  }
}

const pg = await openDatabase();
const db = pgliteDb(pg);
const syncStore = new PgSyncStore(db);
const studentStore = new PgStudentStore(db);
const signer = devCollegeSigner();
const vectors = JSON.parse(readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8')) as {
  keyset_json: KeySetDocument;
  keys: { devices: Array<{ name: string; private_hex: string }> };
};
const keySet = vectors.keyset_json;

// The "phone" behind /_dev/test-pass: the public test device key dev A.
const testDeviceKey = hexToBytes(vectors.keys.devices.find((k) => k.name === 'dev_a')!.private_hex);

const escapeHtml = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

async function testPassPage(roll: string | null): Promise<string> {
  const students = await db.query<{ roll_number: string; name: string }>("select roll_number, name from public.students where status = 'active' order by id");
  const chosen = students.find((s) => s.roll_number.toUpperCase() === (roll ?? '').toUpperCase()) ?? students[0];
  const links = students.map((s) => `<a class="${s === chosen ? 'on' : ''}" href="/_dev/test-pass?roll=${encodeURIComponent(s.roll_number)}">${escapeHtml(s.name)}</a>`).join('');
  const src = chosen ? `/_dev/test-pass.svg?roll=${encodeURIComponent(chosen.roll_number)}` : '';
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Test pass on this screen</title>
<style>
  body { margin: 0; font: 16px system-ui, sans-serif; text-align: center; background: #fff; color: #111; }
  nav { display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; padding: 14px; }
  nav a { padding: 6px 12px; border-radius: 99px; background: #eef1f8; color: #2346a0; text-decoration: none; }
  nav a.on { background: #2346a0; color: #fff; }
  img { width: min(72vh, 92vw); height: min(72vh, 92vw); image-rendering: pixelated; }
  p { margin: 6px 16px; color: #555; }
</style>
<nav>${links}</nav>
${chosen ? `<img id="qr" src="${src}&t=0" alt="Test pass QR for ${escapeHtml(chosen.name)}"><p><b>${escapeHtml(chosen.name)}</b>: a new code is signed every 5 seconds.</p>` : '<p>No students on the roster.</p>'}
<p>For trying the scanner with one phone. This pass is made by this server with the public test keys, not by a student's phone.</p>
<script>setInterval(() => { const i = document.getElementById('qr'); if (i) i.src = '${src}&t=' + Date.now(); }, 5000);</script>`;
}

async function toRequest(req: IncomingMessage): Promise<Request> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') headers.set(name, value);
  }
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  return new Request(`http://${req.headers.host ?? '127.0.0.1'}${req.url ?? '/'}`, { method: req.method, headers, body: hasBody ? Buffer.concat(chunks) : undefined });
}

async function send(res: ServerResponse, response: Response): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, name) => res.setHeader(name, value));
  res.end(Buffer.from(await response.arrayBuffer()));
}

const authDeps = {
  store: studentStore,
  emailDomain: process.env.COLLEGE_EMAIL_DOMAIN,
  exposeOtp,
  deliver: (email: string, code: string) => console.log(`${stamp()} login code for ${email}: ${code}`),
};

const stamp = () => new Date().toISOString().slice(11, 19);

const routes: Record<string, (r: Request) => Promise<Response>> = {
  '/functions/v1/auth-request-otp': (r) => handleRequestOtp(r, authDeps),
  '/functions/v1/auth-verify-otp': (r) => handleVerifyOtp(r, authDeps),
  '/functions/v1/auth-sign-out': (r) => handleSignOut(r, authDeps),
  '/functions/v1/enrol': (r) => handleEnrol(r, { store: studentStore }),
  '/functions/v1/enrolment-status': (r) => handleEnrolmentStatus(r, { store: studentStore }),
  '/functions/v1/issue-credential': (r) => handleIssueCredential(r, { store: studentStore, signer }),
  '/functions/v1/scanner-activate': (r) => handleScannerActivate(r, { store: syncStore, keySet }),
  '/functions/v1/scanner-sync': (r) => handleScannerSync(r, { store: syncStore, keySet }),
};

const server = createServer(async (req, res) => {
  const path = new URL(req.url ?? '/', 'http://x').pathname;
  try {
    const route = routes[path];
    if (route) {
      const response = await route(await toRequest(req));
      console.log(`${stamp()} ${req.method} ${path.replace('/functions/v1/', '')} -> ${response.status}`);
      return await send(res, response);
    }
    if (path === '/') {
      res.statusCode = 302;
      res.setHeader('Location', '/admin');
      return void res.end();
    }
    if (path === '/admin' || path.startsWith('/admin/') || path.startsWith('/_dev/')) {
      const adminRequest = await toRequest(req);
      const blocked = await adminAuth.gate(adminRequest);
      if (blocked) return await send(res, blocked);
      if (path.startsWith('/_dev/')) {
        if (path === '/_dev/scans') {
          const rows = (await pg.query('select scan_id, scanned_at, student_id, roll_number, type, gate, scanner_id, guard_id, entry_method from public.scans order by synced_at, scan_id')).rows;
          return await send(res, Response.json({ count: rows.length, scans: rows }));
        }
        if (path === '/_dev/activation-code') {
          const scanner = new URL(req.url ?? '/', 'http://x').searchParams.get('scanner') ?? 'SC-NEW';
          const code = await issueActivationCode(syncStore, scanner);
          console.log(`${stamp()} activation code for ${scanner}: ${code ?? '(no such scanner)'}`);
          return await send(res, Response.json({ scanner, code }, { status: code ? 200 : 404 }));
        }
        if (path === '/_dev/test-pass') {
          const roll = new URL(req.url ?? '/', 'http://x').searchParams.get('roll');
          return await send(res, new Response(await testPassPage(roll), { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } }));
        }
        if (path === '/_dev/test-pass.svg') {
          const pass = await testPassQr(db, signer, testDeviceKey, new URL(req.url ?? '/', 'http://x').searchParams.get('roll') ?? '');
          if (!pass) return await send(res, Response.json({ error: 'no_such_student' }, { status: 404 }));
          const svg = await QRCode.toString(pass.text, { type: 'svg', errorCorrectionLevel: 'L', margin: 4 });
          return await send(res, new Response(svg, { headers: { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'no-store' } }));
        }
        return await send(res, Response.json({ error: 'not_found' }, { status: 404 }));
      }
      const response = await handleAdmin(adminRequest, { db, issuer: syncStore });
      if (response) return await send(res, response);
    }
    await send(res, Response.json({ error: 'not_found' }, { status: 404 }));
  } catch (error) {
    console.error('server error:', error);
    res.statusCode = 500;
    res.end();
  }
});

server.listen(port, host, () => {
  console.log(`Campus ID local server  (${inMemory ? 'data in memory' : `data kept in ${dataPath}`})`);
  const addresses = host === '0.0.0.0' ? Object.values(networkInterfaces()).flat().filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => (i as { address: string }).address) : [host];
  for (const a of addresses) console.log(`  server address for the apps:  http://${a}:${port}`);
  console.log(`  admin website:                http://${addresses[0]}:${port}/admin`);
  console.log(`  admin password:               ${adminPassword}`);
  console.log(`  login codes are ${exposeOtp ? 'shown in the app and here' : 'only printed here'}; scanner token for SC-DEV: dev-token`);
});

async function stop() {
  server.close();
  await pg.close(); // lets the saved data close cleanly
  process.exit(0);
}
process.on('SIGINT', () => void stop());
process.on('SIGTERM', () => void stop());
