-- 0038: Ensure attendance_records is in supabase_realtime publication and replica identity

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'attendance_records'
  ) then
    execute 'alter publication supabase_realtime add table public.attendance_records';
  end if;
exception when others then
  -- ignore if publication doesn't exist in local env
  null;
end$$;

-- For safety, include full row data in WAL for updates/deletes
alter table if exists public.attendance_records replica identity full;



