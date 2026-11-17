// The login in front of the admin website (/admin, /admin/api/*) and the development pages (/_dev/*).
//
// Everything that can read or export student data sits behind it, always: on the laptop as much as on the
// network. A guard's scanner has its own token (scanner_sync.ts) and that token opens nothing here; the guard
// app has no export of its own.
//
// A password signs the admin in and sets a session cookie (HttpOnly, SameSite=Strict, so another website
// cannot make the browser act on its behalf). Sessions live in memory, so restarting the server signs everyone
// out. This is the prototype's stand-in for real admin accounts and roles (Supabase Auth with
// app_metadata.role = 'admin').

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

export const ADMIN_COOKIE = 'dcid_admin';
export const SESSION_HOURS = 8;
export const MAX_FAILURES = 5;
export const LOCKOUT_SECONDS = 60;

export interface AdminAuthOptions {
  password: string;
  /** Milliseconds since the epoch; tests replace it. */
  now?: () => number;
}

const sha256 = (s: string) => createHash('sha256').update(s).digest();
const escapeHtml = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function loginPage(message?: string): string {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Campus ID admin: sign in</title>
<style>
  :root { --brand:#2346a0; --bg:#eef1f8; --ink:#16213a; --muted:#5b6475; --err:#a3201b; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0b1020; --ink:#e8ecf8; --muted:#9aa4bd; --err:#ff9b94; } .card { background:#141b30 !important; } input { background:#0e1427 !important; color:var(--ink) !important; border-color:#2b3556 !important; } }
  * { box-sizing:border-box; } body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--ink); font:16px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  .card { width:min(92vw,380px); background:#fff; border-radius:22px; padding:30px 28px; box-shadow:0 18px 50px rgba(20,40,120,.16); }
  .mark { width:44px; height:44px; border-radius:14px; background:linear-gradient(135deg,var(--brand),#16306f); margin-bottom:18px; }
  h1 { font-size:22px; margin:0 0 4px; } p { margin:0 0 18px; color:var(--muted); font-size:14px; }
  label { display:block; font-size:13px; font-weight:600; margin-bottom:6px; }
  input { width:100%; font:inherit; padding:12px 14px; border:1.5px solid #c9d0e2; border-radius:12px; }
  input:focus { outline:3px solid rgba(35,70,160,.25); border-color:var(--brand); }
  button { width:100%; margin-top:16px; font:inherit; font-weight:700; padding:13px; border:0; border-radius:999px; background:var(--brand); color:#fff; cursor:pointer; }
  .err { color:var(--err); font-size:14px; margin-top:12px; } .note { font-size:12px; color:var(--muted); margin-top:18px; }
</style>
<form class="card" method="post" action="/admin/login">
  <div class="mark"></div>
  <h1>Campus ID admin</h1>
  <p>Students, passes and the out pass record. Sign in to continue.</p>
  <label for="p">Admin password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" autofocus required>
  ${message ? `<div class="err" role="alert">${escapeHtml(message)}</div>` : ''}
  <button type="submit">Sign in</button>
  <div class="note">Prototype sign-in. Guards do not have this: the guard app can only see today's list.</div>
</form>`;
}

export function createAdminAuth({ password, now = Date.now }: AdminAuthOptions) {
  const sessions = new Map<string, number>(); // token -> expires at (ms)
  let failures: number[] = [];

  const secretMatches = (given: string) => timingSafeEqual(sha256(given), sha256(password));

  function tokenOf(req: Request): string | null {
    const header = req.headers.get('cookie') ?? '';
    for (const part of header.split(';')) {
      const [name, ...rest] = part.trim().split('=');
      if (name === ADMIN_COOKIE) return rest.join('=');
    }
    return null;
  }

  /** Whether this request carries a live admin session. */
  function isAdmin(req: Request): boolean {
    const token = tokenOf(req);
    if (token === null) return false;
    const expires = sessions.get(token);
    if (expires === undefined) return false;
    if (expires <= now()) {
      sessions.delete(token);
      return false;
    }
    return true;
  }

  async function passwordFrom(req: Request): Promise<string> {
    const text = await req.text();
    if (text.length > 2000) return '';
    const type = req.headers.get('content-type') ?? '';
    if (type.includes('application/json')) {
      try {
        const body = JSON.parse(text) as { password?: unknown };
        return typeof body.password === 'string' ? body.password : '';
      } catch {
        return '';
      }
    }
    return new URLSearchParams(text).get('password') ?? '';
  }

  function secondsLocked(): number {
    const t = now();
    failures = failures.filter((f) => t - f < LOCKOUT_SECONDS * 1000);
    return failures.length >= MAX_FAILURES ? Math.ceil((LOCKOUT_SECONDS * 1000 - (t - failures[0])) / 1000) : 0;
  }

  async function login(req: Request): Promise<Response> {
    const wantsJson = (req.headers.get('content-type') ?? '').includes('application/json');
    const locked = secondsLocked();
    if (locked > 0) {
      const message = `Too many wrong passwords. Try again in ${locked} seconds.`;
      return wantsJson
        ? Response.json({ error: 'locked', retry_after_s: locked }, { status: 429 })
        : new Response(loginPage(message), { status: 429, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Retry-After': String(locked) } });
    }
    const given = await passwordFrom(req);
    if (given === '' || !secretMatches(given)) {
      failures.push(now());
      return wantsJson
        ? Response.json({ error: 'wrong_password' }, { status: 401 })
        : new Response(loginPage('That password is not right.'), { status: 401, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }
    failures = [];
    const token = randomBytes(32).toString('base64url');
    sessions.set(token, now() + SESSION_HOURS * 3600 * 1000);
    const headers = new Headers({ 'Set-Cookie': `${ADMIN_COOKIE}=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_HOURS * 3600}` });
    if (wantsJson) return Response.json({ ok: true }, { headers });
    headers.set('Location', '/admin');
    return new Response(null, { status: 303, headers });
  }

  function logout(req: Request): Response {
    const token = tokenOf(req);
    if (token !== null) sessions.delete(token);
    return new Response(null, {
      status: 303,
      headers: { Location: '/admin', 'Set-Cookie': `${ADMIN_COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0` },
    });
  }

  /**
   * For every request to /admin and /_dev. Returns the response to send when the request must not go on (the
   * sign-in page, a sign-in, a refusal), or null when the caller is a signed-in admin and may continue.
   */
  async function gate(req: Request): Promise<Response | null> {
    const url = new URL(req.url);
    if (url.pathname === '/admin/login' && req.method === 'POST') return await login(req);
    if (url.pathname === '/admin/logout') return logout(req);
    if (isAdmin(req)) return null;
    const isPage = req.method === 'GET' && !url.pathname.startsWith('/admin/api/') && !url.pathname.startsWith('/_dev/scans') && !url.pathname.startsWith('/_dev/activation-code');
    if (isPage) return new Response(loginPage(), { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
    return Response.json({ error: 'unauthorized' }, { status: 401, headers: { 'Cache-Control': 'no-store' } });
  }

  return { gate, isAdmin, login, logout };
}
