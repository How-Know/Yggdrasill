-- Realtime publication & replica identity for invalidation-only strategy
do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='students';
  if not found then execute 'alter publication supabase_realtime add table public.students'; end if;
exception when others then null; end $$;

do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='student_basic_info';
  if not found then execute 'alter publication supabase_realtime add table public.student_basic_info'; end if;
exception when others then null; end $$;

do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='student_payment_info';
  if not found then execute 'alter publication supabase_realtime add table public.student_payment_info'; end if;
exception when others then null; end $$;

do $$ begin
  perform 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='student_time_blocks';
  if not found then execute 'alter publication supabase_realtime add table public.student_time_blocks'; end if;
exception when others then null; end $$;

alter table if exists public.students replica identity full;
alter table if exists public.student_basic_info replica identity full;
alter table if exists public.student_payment_info replica identity full;
alter table if exists public.student_time_blocks replica identity full;

