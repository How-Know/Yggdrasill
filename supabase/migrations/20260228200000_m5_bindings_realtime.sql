-- Enable realtime for m5_device_bindings so gateway can detect unbind events
do $$
begin
  perform 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='m5_device_bindings';
  if not found then
    execute 'alter publication supabase_realtime add table public.m5_device_bindings';
  end if;
exception when undefined_object then null;
end $$;

alter table if exists public.m5_device_bindings replica identity full;
