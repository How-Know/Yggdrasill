-- Ensure grouped-homework ordering changes are delivered via realtime.
do $$
begin
  perform 1
    from pg_publication_tables
   where pubname = 'supabase_realtime'
     and schemaname = 'public'
     and tablename = 'homework_groups';
  if not found then
    execute 'alter publication supabase_realtime add table public.homework_groups';
  end if;

  perform 1
    from pg_publication_tables
   where pubname = 'supabase_realtime'
     and schemaname = 'public'
     and tablename = 'homework_group_items';
  if not found then
    execute 'alter publication supabase_realtime add table public.homework_group_items';
  end if;
end
$$;

alter table public.homework_groups replica identity full;
alter table public.homework_group_items replica identity full;
