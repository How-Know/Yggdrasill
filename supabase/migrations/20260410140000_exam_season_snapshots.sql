-- 시험 일정 "시즌" 스냅샷: 새로고침 시 활성 데이터 보관용 (복원은 클라이언트가 payload 기준으로 재삽입)
create table if not exists public.exam_season_snapshots (
  id uuid not null default gen_random_uuid() primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  created_at timestamptz not null default now(),
  payload jsonb not null
);

create index if not exists exam_season_snapshots_academy_created_idx
  on public.exam_season_snapshots (academy_id, created_at desc);

alter table public.exam_season_snapshots enable row level security;

drop policy if exists exam_season_snapshots_all on public.exam_season_snapshots;
create policy exam_season_snapshots_all on public.exam_season_snapshots for all
using (exists (
  select 1 from public.memberships s
  where s.academy_id = exam_season_snapshots.academy_id and s.user_id = auth.uid()
))
with check (exists (
  select 1 from public.memberships s
  where s.academy_id = exam_season_snapshots.academy_id and s.user_id = auth.uid()
));
