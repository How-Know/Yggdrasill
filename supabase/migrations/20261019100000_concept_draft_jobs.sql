-- 20261019100000: 개념 초안 정리를 백그라운드 작업으로 돌린다 (운영자 결정 2026-10-19)
--
-- 설계: docs/architecture/concept-library.md §7
--
-- 정리 AI 호출이 함수 실행 한도(400초) 안에 끝나지 않는 소단원이 있어(2026-10-19 기본 도형 8쪽, 330초 초과),
-- Edge 함수 concept_draft_organize 가 OpenAI 백그라운드 모드로 정리를 시작하고 이 표에 작업을 적는다.
-- 앱은 작업 id로 결과를 물어보고(task collect), 끝난 작업만 서버가 concept_drafts 에 저장한다.
-- 정리 입력(맞춘 블록·기준·유형)은 시작할 때 서버가 읽은 값을 그대로 두어, 결과를 받을 때 다시 읽지 않는다.
-- Edge 함수(서버 키)만 쓴다. 운영자는 읽기만 한다.

create table if not exists public.concept_draft_jobs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null check (btrim(grade_label) <> ''),
  book_name text not null default '',
  unit_path text[] not null default '{}'::text[] check (cardinality(unit_path) <= 3),
  pages integer[] not null check (cardinality(pages) between 1 and 20),
  page_meta jsonb not null default '[]'::jsonb check (jsonb_typeof(page_meta) = 'array'),
  criteria jsonb not null default '[]'::jsonb check (jsonb_typeof(criteria) = 'array'),
  concept_types jsonb not null default '[]'::jsonb check (jsonb_typeof(concept_types) = 'array'),
  prepared jsonb not null check (jsonb_typeof(prepared) = 'object'),
  model text not null,
  prompt_version text not null,
  effort text not null,
  provider text not null,
  -- 공급자 쪽 응답 id. 결과를 받은 뒤 공급자 쪽에서는 지운다.
  response_id text not null unique,
  -- 승인한 "다시 정리" 카드로 시작한 작업이면 그 카드와 지금 초안.
  rerun_action_id uuid references public.ai_actions(id) on delete set null,
  rerun_of uuid references public.concept_drafts(id) on delete set null,
  -- running: 공급자가 정리 중. saving: 결과를 받아 저장하는 중(한 번에 하나만). done·failed: 끝.
  status text not null default 'running' check (status in ('running', 'saving', 'done', 'failed')),
  draft_id uuid references public.concept_drafts(id) on delete set null,
  error text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint concept_draft_jobs_finished_chk check ((status in ('done', 'failed')) = (finished_at is not null))
);

create index if not exists concept_draft_jobs_user_idx
  on public.concept_draft_jobs (created_by, created_at desc);
create index if not exists concept_draft_jobs_active_idx
  on public.concept_draft_jobs (created_at desc) where status in ('running', 'saving');

drop trigger if exists trg_concept_draft_jobs_updated on public.concept_draft_jobs;
create trigger trg_concept_draft_jobs_updated
  before update on public.concept_draft_jobs
  for each row execute function public.set_updated_at();

alter table public.concept_draft_jobs enable row level security;

drop policy if exists concept_draft_jobs_operator_select on public.concept_draft_jobs;
create policy concept_draft_jobs_operator_select on public.concept_draft_jobs
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_draft_jobs from anon;
revoke insert, update, delete, truncate on public.concept_draft_jobs from authenticated;

notify pgrst, 'reload schema';
