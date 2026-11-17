-- Digital Campus ID: initial schema (PRD section 8).
-- Not yet run against a database. Apply with `supabase start` then `supabase db reset`
-- and fix anything it reports before building on it.

-- ---------------------------------------------------------------- helpers

-- Role comes from the JWT's app_metadata, which only the service role can set.
-- Values: 'admin', 'readonly'. Students and scanners have no role claim.
create or replace function public.app_role() returns text
language sql stable
as $$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') $$;

-- ---------------------------------------------------------------- roster and students

-- The roster CSV (A2) is imported into this table. `id` is the `sid` in the credential.
create table public.students (
  id                 bigint generated always as identity primary key,
  roll_number        text not null unique check (roll_number = upper(roll_number) and length(roll_number) between 1 and 16),
  name               text not null check (length(name) between 1 and 64),
  branch             text not null check (length(branch) between 1 and 12),
  year               smallint not null check (year between 1 and 6),
  college_email      text not null unique check (college_email = lower(college_email)),
  phone              text,
  -- false for a student who signed up with a roll-number email and has not yet given name, branch and year
  profile_complete   boolean not null default true,
  status             text not null default 'active' check (status in ('active', 'paused', 'revoked')),
  status_changed_at  timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

create or replace function public.touch_status_changed_at() returns trigger
language plpgsql as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;
  return new;
end $$;

create trigger students_status_changed
  before update on public.students
  for each row execute function public.touch_status_changed_at();

-- ---------------------------------------------------------------- enrolment

create table public.enrolments (
  id            bigint generated always as identity primary key,
  student_id    bigint not null references public.students (id),
  auth_user_id  uuid not null unique references auth.users (id) on delete cascade,
  phone         text not null,
  photo_path    text,                    -- object path in the private `profile-photos` bucket
  photo_hash    bytea check (photo_hash is null or length(photo_hash) = 16),
  status        text not null default 'pending' check (status in ('pending', 'flagged', 'approved', 'rejected')),
  flags         text[] not null default '{}',   -- 'photo_missing', 'mismatch', 'duplicate'
  submitted_at  timestamptz not null default now(),
  reviewed_by   uuid references auth.users (id),
  reviewed_at   timestamptz
);
create index enrolments_status_idx on public.enrolments (status);

-- ---------------------------------------------------------------- devices and credentials

create table public.devices (
  id                 bigint generated always as identity primary key,
  student_id         bigint not null references public.students (id),
  device_public_key  bytea not null check (length(device_public_key) = 33),
  key_version        smallint not null,
  issued_at          timestamptz not null,
  expires_at         timestamptz not null,
  revoked_at         timestamptz,
  created_at         timestamptz not null default now(),
  check (expires_at > issued_at)
);
create index devices_student_idx on public.devices (student_id, issued_at desc);

-- ---------------------------------------------------------------- scanners and guards

create table public.scanners (
  id                     text primary key,            -- e.g. 'SC-01'
  name                   text not null,
  gate                   text not null default 'Main',
  enabled                boolean not null default true,
  activation_code_hash   text,                        -- one-time code the admin hands to the guard
  activation_expires_at  timestamptz,
  token_hash             text,                        -- hash of the API token issued at activation
  last_sync_at           timestamptz,
  created_at             timestamptz not null default now()
);

create table public.guards (
  id          text primary key,                       -- e.g. 'G-03'
  name        text not null,
  scanner_id  text references public.scanners (id),   -- null means any scanner
  pin_hash    text not null,                          -- 'pbkdf2$sha256$<iterations>$<salt b64>$<hash b64>'
  enabled     boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- scan log

-- One row per exit. scan_id is generated on the scanner, so re-sending a batch is harmless:
-- insert ... on conflict (scan_id) do nothing.
-- A manual entry has no credential: the guard types a roll number, the scanner stores it
-- in roll_number and leaves student_id null; sync resolves student_id from the roster.
create table public.scans (
  scan_id       uuid primary key,
  scanned_at    timestamptz not null,                 -- scanner clock after drift correction
  student_id    bigint references public.students (id),
  roll_number   text,
  type          text not null check (type in ('OUT', 'ENTRY_NO_CARD', 'VISITOR')),
  gate          text not null,
  scanner_id    text not null references public.scanners (id),
  guard_id      text not null references public.guards (id),
  entry_method  text not null check (entry_method in ('scan', 'manual')),
  synced_at     timestamptz not null default now(),
  check (student_id is not null or roll_number is not null)
);
create index scans_scanned_at_idx on public.scans (scanned_at desc);
create index scans_student_idx on public.scans (student_id);

create table public.visitors (
  id            bigint generated always as identity primary key,
  visitor_name  text not null,
  phone         text,
  host          text not null,
  purpose       text,
  entry_at      timestamptz not null,
  exit_at       timestamptz,
  scanner_id    text not null references public.scanners (id),
  synced_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------- revocation, settings, audit

-- Signed lists published for scanners; the newest `seq` is served.
create table public.revocation_lists (
  seq          bigint generated always as identity primary key,
  key_version  smallint not null,
  issued_at    timestamptz not null default now(),
  encoded      text not null                          -- the 'DR1.' text from docs/credential-spec.md
);

-- Single-row settings table (A11).
create table public.settings (
  id              boolean primary key default true check (id),
  retention_days  integer not null default 365 check (retention_days >= 30)
);
insert into public.settings default values;

-- Every admin export is itself logged (PRD section 10).
create table public.audit_log (
  id         bigint generated always as identity primary key,
  admin_id   uuid references auth.users (id),
  action     text not null,                           -- 'export_outpass', 'revoke', 'approve', ...
  detail     jsonb not null default '{}',
  row_count  integer,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- views

-- What the revocation list is built from (spec section 7): paused or revoked students, and
-- students whose device was replaced. Entries older than the longest credential life are dropped.
create view public.revocation_entries as
  select student_id as sid, max(revoked_at) as revoked_at
  from (
    select id as student_id, status_changed_at as revoked_at
      from public.students where status <> 'active'
    union all
    select student_id, revoked_at
      from public.devices where revoked_at is not null
  ) r
  where revoked_at > now() - interval '200 days'
  group by student_id;

-- The outpass export (PRD section 8). One row per scan, newest first.
create view public.outpass_export as
  select
    to_char(s.scanned_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') as timestamp,
    coalesce(st.roll_number, s.roll_number)                                     as roll_number,
    st.name,
    case st.year when 1 then 'I' when 2 then 'II' when 3 then 'III' when 4 then 'IV' else st.year::text end as class,
    st.branch,
    st.phone,
    s.type,
    s.gate,
    s.scanner_id,
    s.guard_id,
    s.entry_method,
    s.scanned_at                                                                as scanned_at_utc
  from public.scans s
  left join public.students st
    on st.id = coalesce(s.student_id, (select id from public.students where roll_number = s.roll_number))
  order by s.scanned_at desc;

-- ---------------------------------------------------------------- row level security
-- Edge Functions use the service role, which bypasses RLS. These policies are for the admin
-- panel (browser) and for students reading their own enrolment.

alter table public.students         enable row level security;
alter table public.enrolments       enable row level security;
alter table public.devices          enable row level security;
alter table public.scanners         enable row level security;
alter table public.guards           enable row level security;
alter table public.scans            enable row level security;
alter table public.visitors         enable row level security;
alter table public.revocation_lists enable row level security;
alter table public.settings         enable row level security;
alter table public.audit_log        enable row level security;

do $$
declare t text;
begin
  foreach t in array array['students', 'enrolments', 'devices', 'scanners', 'guards', 'scans', 'visitors', 'revocation_lists', 'settings', 'audit_log']
  loop
    execute format($f$create policy %I on public.%I for select to authenticated using (public.app_role() in ('admin', 'readonly'))$f$, t || '_read', t);
    if t not in ('audit_log', 'revocation_lists') then
      execute format($f$create policy %I on public.%I for all to authenticated using (public.app_role() = 'admin') with check (public.app_role() = 'admin')$f$, t || '_admin_write', t);
    end if;
  end loop;
end $$;

create policy enrolments_own_read on public.enrolments
  for select to authenticated using (auth_user_id = auth.uid());

-- Views run with the caller's rights so they inherit the policies above.
alter view public.revocation_entries set (security_invoker = true);
alter view public.outpass_export     set (security_invoker = true);

-- ---------------------------------------------------------------- sign-up gate (S1)

-- Auth hook: only roster emails may create an account. Enable it in config.toml
-- ([auth.hook.before_user_created]) or the dashboard (Authentication > Hooks).
create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable
as $$
begin
  -- A college email is the roll number at the college's domain (25071a66j1@vnrvjiet.in): an email on the
  -- roster, or one whose name part is a roll number, may sign up. The one-time code then proves the mailbox.
  if exists (
    select 1 from public.students where college_email = lower(event -> 'user' ->> 'email')
  ) or lower(event -> 'user' ->> 'email') ~ '^([0-9]{5}[a-z][0-9a-z]{4}|adm[0-9]{2}-[0-9]{5})@vnrvjiet\.in$' then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Use your college email: your roll number followed by @vnrvjiet.in.'
  ));
end $$;

grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, anon, public;
grant select on public.students to supabase_auth_admin;
