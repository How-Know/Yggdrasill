-- Add student_id to tag_events and supporting index
alter table if exists public.tag_events
  add column if not exists student_id uuid references public.students(id) on delete set null;

create index if not exists idx_tag_events_student on public.tag_events(student_id);



-- Ensure realtime publication for tag_events/homework_items/payment_records
do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tag_events';
  if not found then
    execute 'alter publication supabase_realtime add table public.tag_events';
  end if;
exception when others then null; end $$;

do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='homework_items';
  if not found then
    execute 'alter publication supabase_realtime add table public.homework_items';
  end if;
exception when others then null; end $$;

do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='payment_records';
  if not found then
    execute 'alter publication supabase_realtime add table public.payment_records';
  end if;
exception when others then null; end $$;

-- Use FULL replica identity to emit full row on updates
alter table if exists public.tag_events replica identity full;
alter table if exists public.homework_items replica identity full;
alter table if exists public.payment_records replica identity full;
