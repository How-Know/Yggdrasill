-- Ensure homework detail tables used by M5 payloads emit Supabase Realtime events.
-- The gateway subscribes to these tables so M5 devices update immediately after
-- teacher-side edits, instead of waiting for the device stale refresh.
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;

  foreach t in array array[
    'homework_item_units',
    'homework_item_pages',
    'homework_item_problems',
    'homework_assignment_checks'
  ] loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
