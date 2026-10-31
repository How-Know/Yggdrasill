-- 학부모 알림장 링크. 토큰을 아는 사람만 그 회차의 저장본을 본다.
-- 앱 로그인과 무관하며, anon/authenticated 직접 조회는 막는다.

create table if not exists public.todo_sheet_share_links (
  token text primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  snapshot_id uuid not null
    references public.student_class_session_todo_sheet_snapshots(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists idx_todo_sheet_share_links_snapshot
  on public.todo_sheet_share_links (snapshot_id);

alter table public.todo_sheet_share_links enable row level security;

revoke all on table public.todo_sheet_share_links from public;
revoke all on table public.todo_sheet_share_links from anon;
revoke all on table public.todo_sheet_share_links from authenticated;
