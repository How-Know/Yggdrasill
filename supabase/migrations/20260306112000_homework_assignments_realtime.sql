-- Enable realtime for homework_assignments so M5 list refreshes on assignment status changes
do $$
begin
  perform 1
  from pg_publication_tables
  where pubname = 'supabase_realtime'
    and schemaname = 'public'
    and tablename = 'homework_assignments';
  if not found then
    execute 'alter publication supabase_realtime add table public.homework_assignments';
  end if;
exception when undefined_object then
  null;
end $$;

alter table if exists public.homework_assignments replica identity full;
