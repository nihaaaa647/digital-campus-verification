-- LOCAL DEVELOPMENT ONLY. Loaded by supabase/functions/dev/local_db.ts after the real migration; it is NOT a
-- Supabase migration and must never be applied to a real project.
--
-- On Supabase these three things are done by Supabase itself (email OTP in Auth, sessions as JWTs, photos in
-- Storage). The local server has none of that, so it keeps a small version of each here so the whole
-- sign-up -> approval -> pass loop can be shown on a laptop.

-- One-time login codes, kept hashed. A code is good for 10 minutes and 5 tries.
create table public.dev_otps (
  email       text primary key,
  code_hash   text not null,
  attempts    integer not null default 0,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);

-- Logged-in students. The token itself is never stored, only its hash.
create table public.dev_sessions (
  token_hash    text primary key,
  student_id    bigint not null references public.students (id) on delete cascade,
  auth_user_id  uuid not null,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null
);

-- The enrolment photo (enrolments.photo_path points at the row).
create table public.dev_photos (
  student_id    bigint primary key references public.students (id) on delete cascade,
  content_type  text not null,
  bytes         bytea not null,
  updated_at    timestamptz not null default now()
);
