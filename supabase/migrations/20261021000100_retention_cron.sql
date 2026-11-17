-- Scheduled deletion of old scan logs (A11). Kept in its own migration so it can be dropped or
-- changed without touching the schema. Not yet run against a database.

create extension if not exists pg_cron;

select cron.schedule(
  'delete-old-scans',
  '30 20 * * *',  -- 20:30 UTC = 02:00 IST every day
  $$
    delete from public.scans
    where scanned_at < now() - make_interval(days => (select retention_days from public.settings));
    delete from public.visitors
    where entry_at < now() - make_interval(days => (select retention_days from public.settings));
  $$
);
