-- 학생앱 출결 Realtime: 본인 attendance_records SELECT.
-- 키오스크/학습앱에서 등원·하원이 찍히면 학생앱이 즉시 반영할 수 있게 한다.

drop policy if exists attendance_records_student_app_select on public.attendance_records;
create policy attendance_records_student_app_select on public.attendance_records
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = attendance_records.student_id
      and a.academy_id = attendance_records.academy_id
  )
);

-- publication / replica identity 는 기존 마이그레이션에서 보장되지만 멱등 보강.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'attendance_records'
    ) then
      execute 'alter publication supabase_realtime add table public.attendance_records';
    end if;
  end if;
end $$;

alter table if exists public.attendance_records replica identity full;
