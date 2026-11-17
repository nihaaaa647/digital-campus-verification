// The prototype admin page of the local server (PRD section 6, a small part of it): add students to the roster
// (A1/A2), review and approve enrolments with their photo (A3), create scanners and hand out activation codes
// (A6), and see and download the exits as the outpass table (A8/A9).
//
// It is a single HTML page plus a few JSON routes, for demonstrating the system on a laptop. It is not the
// real admin panel (React, Supabase Auth, roles, audit log): there is no per-person login, only an optional
// shared password, and nothing here is logged. Do not expose it beyond a trusted network.

import { issueActivationCode } from '../_shared/scanner_activate.ts';
import type { ActivationIssuer } from '../_shared/scanner_activate.ts';
import type { Db } from '../_shared/pg_sync_store.ts';
import { normalizeEmail } from '../_shared/student_auth.ts';

export interface AdminDeps {
  db: Db;
  issuer: ActivationIssuer;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

const csvCell = (v: unknown): string => {
  const s = v === null || v === undefined ? '' : v instanceof Date ? v.toISOString() : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
};

const EXIT_COLUMNS = 'timestamp, roll_number, name, class, branch, phone, type, gate, scanner_id, guard_id, entry_method';

/**
 * The search on the exits: `from` and `to` are days (YYYY-MM-DD, India time, both included), `q` is part of a
 * roll number, name, branch or gate. Anything else in the query string is ignored.
 */
export function exitFilter(url: URL): { where: string; params: string[]; from: string | null; to: string | null; q: string } {
  const day = (v: string | null) => (v !== null && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(`${v}T00:00:00Z`)) ? v : null);
  const from = day(url.searchParams.get('from'));
  const to = day(url.searchParams.get('to'));
  const q = (url.searchParams.get('q') ?? '').trim().slice(0, 40);
  const conditions: string[] = [];
  const params: string[] = [];
  if (from !== null) {
    params.push(from);
    conditions.push(`timestamp >= $${params.length}`);
  }
  if (to !== null) {
    params.push(new Date(Date.parse(`${to}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10)); // the day after, so `to` itself is included
    conditions.push(`timestamp < $${params.length}`);
  }
  if (q !== '') {
    params.push(`%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
    conditions.push(`(roll_number ilike $${params.length} or name ilike $${params.length} or branch ilike $${params.length} or gate ilike $${params.length})`);
  }
  return { where: conditions.length > 0 ? `where ${conditions.join(' and ')}` : '', params, from, to, q };
}

async function body(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const parsed = JSON.parse(await req.text());
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

const str = (x: unknown, min: number, max: number): string | null => (typeof x === 'string' && x.trim().length >= min && x.trim().length <= max ? x.trim() : null);

export async function handleAdmin(req: Request, deps: AdminDeps): Promise<Response | null> {
  const url = new URL(req.url);
  const path = url.pathname;
  const { db } = deps;

  if (path === '/admin' && req.method === 'GET') return new Response(ADMIN_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  if (!path.startsWith('/admin/api/')) return null;

  try {
    if (path === '/admin/api/state' && req.method === 'GET') {
      const [students, enrolments, scanners, scans, counts] = await Promise.all([
        db.query('select id::text as id, roll_number, name, branch, year, college_email, phone, status from public.students order by roll_number'),
        db.query(`select e.id::text as id, e.student_id::text as student_id, s.name, s.roll_number, s.branch, s.year, e.phone, e.status, e.flags, e.submitted_at,
                         exists(select 1 from public.dev_photos p where p.student_id = e.student_id) as has_photo
                    from public.enrolments e join public.students s on s.id = e.student_id
                   order by case e.status when 'flagged' then 0 when 'pending' then 1 else 2 end, e.submitted_at desc`),
        db.query(`select id, name, gate, enabled, token_hash is not null as activated, last_sync_at from public.scanners order by id`),
        db.query('select timestamp, roll_number, name, class, branch, phone, type, gate, scanner_id, guard_id, entry_method from public.outpass_export limit 200'),
        db.query(`select (select count(*) from public.scans)::int as exits, (select count(*) from public.scans where scanned_at >= date_trunc('day', now()))::int as today`),
      ]);
      return json({ students, enrolments, scanners, scans, counts: counts[0] });
    }

    if (path === '/admin/api/students' && req.method === 'POST') {
      const b = await body(req);
      const roll = str(b?.roll_number, 1, 16)?.toUpperCase() ?? null;
      const name = str(b?.name, 1, 64);
      const branch = str(b?.branch, 1, 12);
      const email = normalizeEmail(b?.college_email);
      const year = typeof b?.year === 'number' ? b.year : Number(b?.year);
      if (!roll || !name || !branch || !email || !Number.isInteger(year) || year < 1 || year > 6) return json({ error: 'Check every field: roll number, name, branch, year 1 to 6, and a valid email.' }, 400);
      try {
        await db.query('insert into public.students (roll_number, name, branch, year, college_email) values ($1, $2, $3, $4::smallint, $5)', [roll, name, branch, year, email]);
      } catch (error) {
        return json({ error: /unique|duplicate/i.test(String(error)) ? 'That roll number or email is already on the roster.' : 'Could not add the student.' }, 409);
      }
      return json({ ok: true });
    }

    const review = /^\/admin\/api\/enrolments\/(\d+)\/(approve|reject)$/.exec(path);
    if (review && req.method === 'POST') {
      const status = review[2] === 'approve' ? 'approved' : 'rejected';
      const rows = await db.query(
        `update public.enrolments set status = $2, reviewed_at = now() where id = $1::bigint and status in ('pending', 'flagged', 'rejected', 'approved') returning id::text as id`,
        [review[1], status],
      );
      return rows.length ? json({ ok: true, status }) : json({ error: 'No such enrolment.' }, 404);
    }

    const photo = /^\/admin\/api\/photo\/(\d+)$/.exec(path);
    if (photo && req.method === 'GET') {
      const rows = await db.query<{ content_type: string; bytes: unknown }>('select content_type, bytes from public.dev_photos where student_id = $1::bigint', [photo[1]]);
      if (!rows[0]) return new Response('no photo', { status: 404 });
      return new Response(new Uint8Array(rows[0].bytes as ArrayLike<number>), { headers: { 'Content-Type': rows[0].content_type, 'Cache-Control': 'no-store' } });
    }

    if (path === '/admin/api/scanners' && req.method === 'POST') {
      const b = await body(req);
      const id = str(b?.id, 1, 24)?.toUpperCase() ?? null;
      const name = str(b?.name, 1, 64);
      const gate = str(b?.gate, 1, 64);
      if (!id || !name || !gate || !/^[A-Z0-9-]+$/.test(id)) return json({ error: 'Give the scanner an id (letters, digits, hyphen), a name and a gate.' }, 400);
      try {
        await db.query('insert into public.scanners (id, name, gate) values ($1, $2, $3)', [id, name, gate]);
      } catch {
        return json({ error: 'A scanner with that id already exists.' }, 409);
      }
      return json({ ok: true });
    }

    const code = /^\/admin\/api\/scanners\/([A-Za-z0-9-]+)\/code$/.exec(path);
    if (code && req.method === 'POST') {
      const issued = await issueActivationCode(deps.issuer, code[1]);
      return issued ? json({ code: issued, valid_minutes: 15 }) : json({ error: 'No such scanner.' }, 404);
    }

    if (path === '/admin/api/exits' && req.method === 'GET') {
      const f = exitFilter(url);
      const rows = await db.query(`select ${EXIT_COLUMNS} from public.outpass_export ${f.where} limit 500`, f.params);
      const total = await db.query<{ n: string }>(`select count(*)::text as n from public.outpass_export ${f.where}`, f.params);
      return json({ rows, total: Number(total[0].n), shown: rows.length });
    }

    if (path === '/admin/api/exits.csv' && req.method === 'GET') {
      const f = exitFilter(url);
      const rows = await db.query<Record<string, unknown>>(`select ${EXIT_COLUMNS} from public.outpass_export ${f.where}`, f.params);
      const header = ['Timestamp', 'Roll number', 'Name', 'Class', 'Branch', 'Phone', 'Type', 'Gate', 'Scanner', 'Guard', 'Entry method'];
      const lines = [header.join(','), ...rows.map((r) => [r.timestamp, r.roll_number, r.name, r.class, r.branch, r.phone, r.type, r.gate, r.scanner_id, r.guard_id, r.entry_method].map(csvCell).join(','))];
      return new Response('﻿' + lines.join('\r\n') + '\r\n', {
        headers: { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="${f.from || f.to ? `outpass-${f.from ?? 'start'}-to-${f.to ?? 'now'}.csv` : 'outpass-export.csv'}"`, 'Cache-Control': 'no-store' },
      });
    }
  } catch (error) {
    console.error('admin failed:', error instanceof Error ? error.message : String(error));
    return json({ error: 'Something went wrong on the server.' }, 500);
  }
  return json({ error: 'not_found' }, 404);
}

const ADMIN_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Campus ID admin (prototype)</title>
<style>
  :root { --brand:#2346a0; --bg:#f2f5fb; --card:#fff; --ink:#111827; --muted:#5b6475; --line:#e3e7ef; --ok:#137333; --bad:#b3261e; --warn:#b26a00; }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.45 system-ui,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--ink); }
  header { background:var(--brand); color:#fff; padding:14px 24px; display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  header h1 { font-size:20px; margin:0; letter-spacing:-.2px; }
  header .tag { background:#ffc107; color:#1f1a00; font-weight:700; font-size:12px; padding:3px 10px; border-radius:99px; }
  header .stats { margin-left:auto; display:flex; gap:20px; font-size:14px; }
  header .stats b { font-size:20px; display:block; line-height:1.1; }
  nav { display:flex; gap:4px; padding:12px 24px 0; flex-wrap:wrap; }
  nav button { border:0; background:transparent; font:inherit; font-weight:600; color:var(--muted); padding:10px 16px; border-radius:10px 10px 0 0; cursor:pointer; }
  nav button.on { background:var(--card); color:var(--brand); }
  nav .badge { background:var(--bad); color:#fff; border-radius:99px; font-size:12px; padding:1px 8px; margin-left:6px; }
  main { background:var(--card); margin:0 24px 24px; padding:20px; border-radius:0 12px 12px 12px; min-height:300px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  table { width:100%; border-collapse:collapse; }
  th { text-align:left; font-size:12px; letter-spacing:.8px; text-transform:uppercase; color:var(--muted); padding:8px; border-bottom:2px solid var(--line); }
  td { padding:10px 8px; border-bottom:1px solid var(--line); vertical-align:middle; }
  .pill { display:inline-block; padding:2px 10px; border-radius:99px; font-size:12px; font-weight:700; background:var(--line); color:var(--muted); }
  .pill.approved,.pill.active { background:#d7efe0; color:var(--ok); } .pill.pending { background:#e5ecff; color:var(--brand); }
  .pill.flagged,.pill.rejected { background:#fbe0de; color:var(--bad); }
  button.act { border:0; border-radius:99px; padding:7px 16px; font:inherit; font-weight:700; cursor:pointer; margin-right:6px; }
  button.go { background:var(--ok); color:#fff; } button.no { background:#fff; color:var(--bad); border:2px solid var(--bad); } button.pri { background:var(--brand); color:#fff; }
  img.photo { width:72px; height:72px; object-fit:cover; border-radius:12px; background:var(--line); }
  form { display:grid; grid-template-columns:repeat(auto-fill,minmax(170px,1fr)); gap:10px; margin-bottom:20px; align-items:end; }
  label { font-size:12px; font-weight:700; color:var(--muted); display:block; }
  input { width:100%; padding:9px 10px; border:1px solid #c9cfdb; border-radius:8px; font:inherit; }
  .msg { padding:10px 14px; border-radius:10px; margin-bottom:14px; font-weight:600; }
  .msg.err { background:#fbe0de; color:var(--bad); } .msg.ok { background:#d7efe0; color:var(--ok); }
  .code { font:700 30px/1 ui-monospace,Consolas,monospace; letter-spacing:6px; color:var(--brand); }
  .empty { color:var(--muted); padding:30px 0; text-align:center; }
  .muted { color:var(--muted); font-size:13px; }
  a.out { margin-left:auto; color:#fff; opacity:.85; font-size:13px; text-decoration:none; border:1px solid rgba(255,255,255,.4); border-radius:999px; padding:5px 12px; }
  .filter { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; margin:0 0 14px; } .filter label { display:block; font-size:12px; font-weight:600; color:var(--muted); margin-bottom:3px; }
  .filter input { font:inherit; padding:8px 10px; border:1px solid #c9d0e2; border-radius:10px; }
</style></head>
<body>
<header><h1>Campus ID &middot; admin</h1><span class="tag">PROTOTYPE &middot; LOCAL SERVER</span><a class="out" href="/admin/logout">Sign out</a>
  <div class="stats"><div><b id="s-exits">0</b>exits in total</div><div><b id="s-today">0</b>exits today</div><div><b id="s-wait">0</b>waiting for approval</div></div></header>
<nav id="tabs"></nav><main id="main"></main>
<script>
const TABS = [['enrol','Enrolments'],['roster','Roster'],['scanners','Scanners'],['exits','Exits']];
let tab = location.hash.slice(1) || 'enrol', state = null, notice = null, busy = false, fx = {from:'',to:'',q:''}, exitRows = null;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const when = s => s ? new Date(s).toLocaleString() : '';
async function api(path, opts) { const r = await fetch('/admin/api/' + path, opts); const t = r.headers.get('content-type')||''; const b = t.includes('json') ? await r.json() : null; if (!r.ok) throw new Error((b && b.error) || 'Request failed'); return b; }
const post = (path, data) => api(path, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(data||{}) });
async function loadExits() { const qs = new URLSearchParams(Object.fromEntries(Object.entries(fx).filter(([, v]) => v))).toString(); exitRows = qs ? await api('exits?' + qs) : null; }
async function load() { if (busy) return; try { state = await api('state'); if (tab === 'exits') await loadExits(); render(); } catch (e) { document.getElementById('main').innerHTML = '<div class="msg err">' + esc(e.message) + '</div>'; } }
function stats() { document.getElementById('s-exits').textContent = state.counts.exits; document.getElementById('s-today').textContent = state.counts.today; document.getElementById('s-wait').textContent = state.enrolments.filter(e => e.status==='pending'||e.status==='flagged').length; }
function tabs() { const wait = state.enrolments.filter(e => e.status==='pending'||e.status==='flagged').length; document.getElementById('tabs').innerHTML = TABS.map(([k,l]) => '<button class="'+(k===tab?'on':'')+'" data-t="'+k+'">'+l+(k==='enrol'&&wait?'<span class="badge">'+wait+'</span>':'')+'</button>').join(''); }
function render() { stats(); tabs(); const m = document.getElementById('main'); const n = notice ? '<div class="msg '+notice.k+'">'+notice.t+'</div>' : ''; m.innerHTML = n + views[tab](); }
const views = {
  enrol() { if (!state.enrolments.length) return '<div class="empty">No one has registered yet. Students register in the app; their request appears here.</div>';
    return '<table><tr><th>Photo</th><th>Student</th><th>Phone</th><th>Submitted</th><th>Status</th><th></th></tr>' + state.enrolments.map(e =>
      '<tr><td>'+(e.has_photo?'<img class="photo" src="/admin/api/photo/'+e.student_id+'?'+Date.parse(e.submitted_at)+'">':'')+'</td><td><b>'+esc(e.name)+'</b><br><span class="muted">'+esc(e.roll_number)+' &middot; '+esc(e.branch)+' &middot; year '+esc(e.year)+'</span></td><td>'+esc(e.phone)+'</td><td class="muted">'+when(e.submitted_at)+'</td><td><span class="pill '+esc(e.status)+'">'+esc(e.status)+'</span>'+(e.flags&&e.flags.length?'<br><span class="muted">'+esc(e.flags.join(', '))+'</span>':'')+'</td><td>'+
      (e.status==='approved'?'':'<button class="act go" data-a="approve" data-id="'+e.id+'">Approve</button>')+(e.status==='rejected'?'':'<button class="act no" data-a="reject" data-id="'+e.id+'">Reject</button>')+'</td></tr>').join('') + '</table>'; },
  roster() { return '<form id="f-student"><div><label>Roll number</label><input name="roll_number" required maxlength="16"></div><div><label>Name</label><input name="name" required maxlength="64"></div><div><label>Branch</label><input name="branch" required maxlength="12" placeholder="CSE"></div><div><label>Year (1-6)</label><input name="year" type="number" min="1" max="6" required></div><div><label>College email</label><input name="college_email" type="email" required></div><div><button class="act pri" type="submit">Add student</button></div></form>' +
    '<table><tr><th>Roll</th><th>Name</th><th>Branch</th><th>Year</th><th>Email</th><th>Phone</th><th>Status</th></tr>' + state.students.map(s => '<tr><td>'+esc(s.roll_number)+'</td><td>'+esc(s.name)+'</td><td>'+esc(s.branch)+'</td><td>'+esc(s.year)+'</td><td>'+esc(s.college_email)+'</td><td>'+esc(s.phone)+'</td><td><span class="pill '+esc(s.status)+'">'+esc(s.status)+'</span></td></tr>').join('') + '</table>'; },
  scanners() { return '<form id="f-scanner"><div><label>Scanner id</label><input name="id" required maxlength="24" placeholder="SC-02"></div><div><label>Name</label><input name="name" required maxlength="64" placeholder="Back gate 1"></div><div><label>Gate</label><input name="gate" required maxlength="64" placeholder="Back gate"></div><div><button class="act pri" type="submit">Add scanner</button></div></form>' +
    '<table><tr><th>Scanner</th><th>Gate</th><th>State</th><th>Last sync</th><th></th></tr>' + state.scanners.map(s => '<tr><td><b>'+esc(s.id)+'</b><br><span class="muted">'+esc(s.name)+'</span></td><td>'+esc(s.gate)+'</td><td><span class="pill '+(s.activated?'approved':'pending')+'">'+(s.activated?'activated':'not activated')+'</span></td><td class="muted">'+(s.last_sync_at?when(s.last_sync_at):'never')+'</td><td><button class="act pri" data-a="code" data-id="'+esc(s.id)+'">New activation code</button></td></tr>').join('') + '</table><p class="muted">A code works once, for 15 minutes. Type it into the scanner app with this server\\'s address. A new code for an already activated scanner replaces its token.</p>'; },
  exits() { const rows = exitRows ? exitRows.rows : state.scans; const total = exitRows ? exitRows.total : state.counts.exits;
    const qs = new URLSearchParams(Object.fromEntries(Object.entries(fx).filter(([, v]) => v))).toString();
    return '<form class="filter" id="f-exits"><div><label>From</label><input type="date" name="from" value="'+esc(fx.from)+'"></div><div><label>To</label><input type="date" name="to" value="'+esc(fx.to)+'"></div>' +
      '<div><label>Search name, roll number, branch, gate</label><input type="search" name="q" value="'+esc(fx.q)+'" placeholder="name or roll number" size="26"></div>' +
      '<button class="act pri" type="submit">Search</button><button class="act" type="button" data-a="clear-filter">Clear</button>' +
      '<a href="/admin/api/exits.csv'+(qs?'?'+qs:'')+'"><button class="act pri" type="button">Download CSV'+(qs?' of this search':' of everything')+'</button></a></form>' +
      '<p class="muted">'+total+' exit'+(total===1?'':'s')+(exitRows?' match':' in total')+(rows.length<total?' (the newest '+rows.length+' are shown; the CSV has all of them)':'')+'. One row per student let through, newest first, with the phone number from the roster.</p>' +
      (!rows.length ? '<div class="empty">'+(exitRows?'No exits match that search.':'No exits yet. They appear here a few seconds after a guard scans a pass.')+'</div>' :
    '<table><tr><th>Time</th><th>Roll</th><th>Name</th><th>Class</th><th>Branch</th><th>Phone</th><th>Gate</th><th>Scanner</th><th>Method</th></tr>' + rows.map(s => '<tr><td>'+esc(s.timestamp)+'</td><td>'+esc(s.roll_number)+'</td><td>'+esc(s.name)+'</td><td>'+esc(s.class)+'</td><td>'+esc(s.branch)+'</td><td>'+esc(s.phone)+'</td><td>'+esc(s.gate)+'</td><td>'+esc(s.scanner_id)+'</td><td>'+esc(s.entry_method)+'</td></tr>').join('') + '</table>'); },
};
document.addEventListener('click', async e => { const t = e.target.closest('[data-t]'); if (t) { tab = t.dataset.t; location.hash = tab; notice = null; render(); return; }
  const a = e.target.closest('[data-a]'); if (!a) return;
  if (a.dataset.a === 'clear-filter') { fx = {from:'',to:'',q:''}; exitRows = null; render(); return; }
  busy = true;
  try { if (a.dataset.a === 'code') { const r = await post('scanners/' + a.dataset.id + '/code'); notice = {k:'ok', t:'Activation code for '+esc(a.dataset.id)+': <span class="code">'+esc(r.code)+'</span> &nbsp;(valid '+r.valid_minutes+' minutes)'}; }
    else { await post('enrolments/' + a.dataset.id + '/' + a.dataset.a); notice = {k:'ok', t:'Enrolment ' + (a.dataset.a==='approve'?'approved':'rejected') + '.'}; } }
  catch (err) { notice = {k:'err', t:esc(err.message)}; } busy = false; await load(); });
document.addEventListener('submit', async e => { e.preventDefault(); const f = e.target;
  if (f.id === 'f-exits') { fx = Object.assign({from:'',to:'',q:''}, Object.fromEntries(new FormData(f))); try { await loadExits(); } catch (err) { notice = {k:'err', t:esc(err.message)}; } render(); return; }
  const data = Object.fromEntries(new FormData(f)); busy = true;
  try { await post(f.id === 'f-student' ? 'students' : 'scanners', data); notice = {k:'ok', t:'Added.'}; } catch (err) { notice = {k:'err', t:esc(err.message)}; } busy = false; await load(); });
load(); setInterval(() => { if (!document.activeElement || document.activeElement.tagName !== 'INPUT') load(); }, 4000);
</script></body></html>`;
