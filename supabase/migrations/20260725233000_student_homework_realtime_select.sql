-- 학생앱 과제 Realtime: 본인 행 SELECT + group_runtime 발행.
-- 학습앱과 같이 Realtime 이벤트 + 짧은 폴백 폴링이 가능하도록 한다.

-- 1) homework_group_runtime RLS (기존엔 없음)
alter table public.homework_group_runtime enable row level security;

drop policy if exists homework_group_runtime_staff_all on public.homework_group_runtime;
create policy homework_group_runtime_staff_all on public.homework_group_runtime
for all to authenticated
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_group_runtime.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_group_runtime.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists homework_group_runtime_student_select on public.homework_group_runtime;
create policy homework_group_runtime_student_select on public.homework_group_runtime
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = homework_group_runtime.student_id
      and a.academy_id = homework_group_runtime.academy_id
  )
);

-- 2) 학생 본인 과제 행 SELECT (Realtime payload / 폴백 폴링용)
drop policy if exists homework_items_student_app_select on public.homework_items;
create policy homework_items_student_app_select on public.homework_items
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = homework_items.student_id
      and a.academy_id = homework_items.academy_id
  )
);

drop policy if exists homework_groups_student_app_select on public.homework_groups;
create policy homework_groups_student_app_select on public.homework_groups
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = homework_groups.student_id
      and a.academy_id = homework_groups.academy_id
  )
);

drop policy if exists homework_group_items_student_app_select on public.homework_group_items;
create policy homework_group_items_student_app_select on public.homework_group_items
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = homework_group_items.student_id
      and a.academy_id = homework_group_items.academy_id
  )
);

-- 3) Realtime publication + replica identity
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'homework_group_runtime'
    ) then
      execute 'alter publication supabase_realtime add table public.homework_group_runtime';
    end if;
  end if;
end $$;

alter table public.homework_group_runtime replica identity full;
alter table if exists public.homework_items replica identity full;
