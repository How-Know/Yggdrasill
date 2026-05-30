-- Ensure attendance_records is published for realtime so the M5 gateway can
-- react to departures (하원) and refresh student lists on unbound devices.
-- Idempotent: only adds the table if not already in the supabase_realtime publication.

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'attendance_records'
    ) then
      alter publication supabase_realtime add table public.attendance_records;
    end if;
  end if;
end $$;
