-- 학생별 과제 출제 교재 활성 상태 override.
-- 행이 없으면 클라이언트가 현재 학년/과정 기준 기본값을 계산한다.
create table if not exists public.student_textbook_link_preferences (
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  flow_id uuid not null references public.student_flows(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  enabled boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (academy_id, student_id, flow_id, book_id, grade_label)
);

create index if not exists idx_student_textbook_link_preferences_student
  on public.student_textbook_link_preferences (academy_id, student_id);

alter table public.student_textbook_link_preferences enable row level security;

drop policy if exists student_textbook_link_preferences_select
  on public.student_textbook_link_preferences;
create policy student_textbook_link_preferences_select
on public.student_textbook_link_preferences for select
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_textbook_link_preferences.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists student_textbook_link_preferences_insert
  on public.student_textbook_link_preferences;
create policy student_textbook_link_preferences_insert
on public.student_textbook_link_preferences for insert
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_textbook_link_preferences.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists student_textbook_link_preferences_update
  on public.student_textbook_link_preferences;
create policy student_textbook_link_preferences_update
on public.student_textbook_link_preferences for update
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_textbook_link_preferences.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_textbook_link_preferences.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists student_textbook_link_preferences_delete
  on public.student_textbook_link_preferences;
create policy student_textbook_link_preferences_delete
on public.student_textbook_link_preferences for delete
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_textbook_link_preferences.academy_id
      and m.user_id = auth.uid()
  )
);
