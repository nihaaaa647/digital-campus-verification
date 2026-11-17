-- Development data. `supabase db reset` runs this after the migrations (see [db.seed] in config.toml).
-- NEVER load it into a real project: it contains a scanner whose token is published in the repository.

-- One student, so a scan from the demo pass or the sample test vectors has someone to point at.
insert into public.students (roll_number, name, branch, year, college_email)
values ('25071A0001', 'Sample Student', 'CSE-AIML', 2, '25071a0001@vnrvjiet.in');

-- A scanner whose token is the plain text `dev-token`. token_hash is the lower-case hex SHA-256 of the
-- token, which is how scanner-activate will store the tokens it hands out.
insert into public.scanners (id, name, gate, token_hash)
values ('SC-DEV', 'Development scanner', 'Main', 'c91cbbedf8c712e8e2b7517ddeca8fe4fde839ebd8339e0b2001363002b37712');

-- The placeholder guard the scanner app uses until guard login exists (apps/scanner_app devGateContext).
-- The pin_hash is not a real PBKDF2 hash; nobody can log in with it.
insert into public.guards (id, name, pin_hash)
values ('G-DEV', 'Development guard', 'pbkdf2$sha256$1$AAAA$AAAA');

-- A scanner with no token yet, for trying scanner-activate: generate it a code (see supabase/README.md),
-- type the code into the scanner app, and it gets its own token.
insert into public.scanners (id, name, gate)
values ('SC-NEW', 'New scanner (not activated)', 'North gate');

-- More students, so a demo has a roster to register from. Their emails are fake: the local server shows the
-- login code on screen instead of sending mail.
insert into public.students (roll_number, name, branch, year, college_email) values
  ('25071A0002', 'Anita Rao',        'ECE',      3, '25071a0002@vnrvjiet.in'),
  ('25071A0003', 'Ravi Kumar',       'CSE',      1, '25071a0003@vnrvjiet.in'),
  ('25071A0004', 'Meera Iyer',       'MECH',     4, '25071a0004@vnrvjiet.in'),
  ('ADM26-00317', 'Śrāvya Ñandini',  'ECE',      1, 'adm26-00317@vnrvjiet.in');
