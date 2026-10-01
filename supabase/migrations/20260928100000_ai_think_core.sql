-- 20260928100000: AI Think 기반 (매니저앱 슈퍼관리자 전용)
-- - 대화/메시지, 기억(교육철학·원칙·결정·메모)과 변경 이력, AI 호출 기록, 플랫폼 AI 설정
-- - 첨부 파일 버킷 `ai-attachments` (비공개)
-- - 기억 검색 / 사용량 집계 RPC
-- 설계: docs/architecture/ai.md

-- ---------------------------------------------------------------------------
-- 1) 대화
-- ---------------------------------------------------------------------------
create table if not exists public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  title text not null default '새 대화',
  status text not null default 'active' check (status in ('active', 'archived')),
  scope_type text not null default 'general'
    check (scope_type in ('general', 'student', 'problem', 'curriculum', 'knowledge', 'project')),
  scope_id text,
  message_count integer not null default 0,
  last_message_at timestamptz,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_ai_conversations_recent
  on public.ai_conversations (status, last_message_at desc nulls last);

drop trigger if exists trg_ai_conversations_updated_at on public.ai_conversations;
create trigger trg_ai_conversations_updated_at
  before update on public.ai_conversations
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2) AI 호출 기록 (모든 AI 기능 공통, Edge Function이 service role로 기록)
-- ---------------------------------------------------------------------------
create table if not exists public.ai_runs (
  id uuid primary key default gen_random_uuid(),
  feature text not null,
  provider text not null,
  model text not null,
  prompt_version text,
  status text not null check (status in ('ok', 'error', 'stopped')),
  error text,
  input_tokens integer not null default 0,
  cached_input_tokens integer not null default 0,
  cache_write_tokens integer not null default 0,
  output_tokens integer not null default 0,
  reasoning_tokens integer not null default 0,
  web_search_calls integer not null default 0,
  tool_calls integer not null default 0,
  cost_usd numeric(12, 6),
  latency_ms integer,
  conversation_id uuid references public.ai_conversations(id) on delete set null,
  academy_id uuid references public.academies(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_ai_runs_created_at on public.ai_runs (created_at desc);
create index if not exists idx_ai_runs_feature_created_at on public.ai_runs (feature, created_at desc);
create index if not exists idx_ai_runs_created_by_created_at on public.ai_runs (created_by, created_at desc);

-- ---------------------------------------------------------------------------
-- 3) 메시지
-- ---------------------------------------------------------------------------
create table if not exists public.ai_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null default '',
  status text not null default 'complete' check (status in ('complete', 'error', 'stopped')),
  attachments jsonb not null default '[]'::jsonb,
  sources jsonb not null default '[]'::jsonb,
  tool_calls jsonb not null default '[]'::jsonb,
  commentary text,
  model text,
  run_id uuid references public.ai_runs(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists idx_ai_messages_conversation
  on public.ai_messages (conversation_id, created_at);

create or replace function public.ai_messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ai_conversations
     set last_message_at = new.created_at,
         message_count = message_count + 1
   where id = new.conversation_id;
  return null;
end
$$;

drop trigger if exists trg_ai_messages_after_insert on public.ai_messages;
create trigger trg_ai_messages_after_insert
  after insert on public.ai_messages
  for each row execute function public.ai_messages_after_insert();

-- ---------------------------------------------------------------------------
-- 4) 기억: identity(교육철학) / principle(합의된 원칙) / decision(결정) / note(메모)
--    원본은 이 테이블이다. docs/assessment/philosophy.md는 초기값으로만 쓰였다.
-- ---------------------------------------------------------------------------
create table if not exists public.ai_memories (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('identity', 'principle', 'decision', 'note')),
  status text not null default 'active' check (status in ('draft', 'active', 'superseded', 'archived')),
  title text not null,
  content text not null default '',
  decision_context text,
  decision_reason text,
  alternatives text[] not null default '{}',
  tags text[] not null default '{}',
  sort_order integer not null default 0,
  supersedes_id uuid references public.ai_memories(id) on delete set null,
  source_conversation_id uuid references public.ai_conversations(id) on delete set null,
  spec_path text,
  spec_exported_at timestamptz,
  version integer not null default 1,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_ai_memories_kind_status
  on public.ai_memories (kind, status, sort_order, updated_at desc);

create table if not exists public.ai_memory_revisions (
  id bigserial primary key,
  memory_id uuid not null references public.ai_memories(id) on delete cascade,
  version integer not null,
  snapshot jsonb not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create index if not exists idx_ai_memory_revisions_memory
  on public.ai_memory_revisions (memory_id, version desc);

-- version은 서버가 올린다. 클라이언트는 `.eq('version', expected)`로 동시 수정을 감지한다.
create or replace function public.ai_memories_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.version := 1;
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.updated_at := now();
    if new.status = 'active' and new.approved_at is null then
      new.approved_at := now();
      new.approved_by := coalesce(new.approved_by, auth.uid());
    end if;
  else
    new.version := old.version + 1;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), new.updated_by);
    if new.status = 'active' and old.status is distinct from 'active' then
      new.approved_at := now();
      new.approved_by := coalesce(auth.uid(), new.approved_by);
    end if;
  end if;
  return new;
end
$$;

drop trigger if exists trg_ai_memories_before_write on public.ai_memories;
create trigger trg_ai_memories_before_write
  before insert or update on public.ai_memories
  for each row execute function public.ai_memories_before_write();

create or replace function public.ai_memories_after_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ai_memory_revisions (memory_id, version, snapshot, changed_by)
  values (new.id, new.version, to_jsonb(new), auth.uid());
  return null;
end
$$;

drop trigger if exists trg_ai_memories_after_write on public.ai_memories;
create trigger trg_ai_memories_after_write
  after insert or update on public.ai_memories
  for each row execute function public.ai_memories_after_write();

-- ---------------------------------------------------------------------------
-- 5) 플랫폼 AI 설정 (단일 행). 비용은 플랫폼이 통합 부담한다.
-- ---------------------------------------------------------------------------
create table if not exists public.ai_platform_settings (
  id boolean primary key default true check (id),
  monthly_budget_usd numeric(10, 2) check (monthly_budget_usd is null or monthly_budget_usd >= 0),
  budget_mode text not null default 'warn' check (budget_mode in ('warn', 'block')),
  web_search_enabled boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.ai_platform_settings (id) values (true)
on conflict (id) do nothing;

create or replace function public.ai_platform_settings_before_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.id := true;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end
$$;

drop trigger if exists trg_ai_platform_settings_before_update on public.ai_platform_settings;
create trigger trg_ai_platform_settings_before_update
  before update on public.ai_platform_settings
  for each row execute function public.ai_platform_settings_before_update();

-- ---------------------------------------------------------------------------
-- 6) RLS: 슈퍼관리자 전용. ai_runs 쓰기는 service role(Edge Function)만.
-- ---------------------------------------------------------------------------
alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;
alter table public.ai_memories enable row level security;
alter table public.ai_memory_revisions enable row level security;
alter table public.ai_runs enable row level security;
alter table public.ai_platform_settings enable row level security;

drop policy if exists ai_conversations_superadmin on public.ai_conversations;
create policy ai_conversations_superadmin on public.ai_conversations
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

drop policy if exists ai_messages_superadmin on public.ai_messages;
create policy ai_messages_superadmin on public.ai_messages
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

drop policy if exists ai_memories_superadmin on public.ai_memories;
create policy ai_memories_superadmin on public.ai_memories
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

drop policy if exists ai_memory_revisions_superadmin_select on public.ai_memory_revisions;
create policy ai_memory_revisions_superadmin_select on public.ai_memory_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_runs_superadmin_select on public.ai_runs;
create policy ai_runs_superadmin_select on public.ai_runs
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_platform_settings_superadmin_select on public.ai_platform_settings;
create policy ai_platform_settings_superadmin_select on public.ai_platform_settings
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_platform_settings_superadmin_update on public.ai_platform_settings;
create policy ai_platform_settings_superadmin_update on public.ai_platform_settings
  for update to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

-- ---------------------------------------------------------------------------
-- 7) RPC
-- ---------------------------------------------------------------------------
-- 검색어 정규화(조사 제거 등)는 Edge Function(_shared/ai/search_terms.ts)이 한다.
create or replace function public.ai_search_memories(p_terms text[], p_limit integer default 8)
returns table (
  id uuid,
  kind text,
  status text,
  title text,
  content text,
  decision_context text,
  decision_reason text,
  alternatives text[],
  tags text[],
  updated_at timestamptz,
  score integer
)
language sql
stable
security invoker
set search_path = public
as $$
  with terms as (
    select distinct lower(trim(t)) as t
    from unnest(coalesce(p_terms, '{}'::text[])) as t
    where length(trim(t)) >= 2
  ),
  scored as (
    select m.*,
           (
             select count(*)::integer
             from terms
             where position(
               terms.t in lower(
                 m.title || ' ' || m.content || ' ' ||
                 coalesce(m.decision_context, '') || ' ' ||
                 coalesce(m.decision_reason, '') || ' ' ||
                 array_to_string(m.alternatives, ' ') || ' ' ||
                 array_to_string(m.tags, ' ')
               )
             ) > 0
           ) as score
    from public.ai_memories m
    where m.status in ('active', 'draft')
  )
  select s.id, s.kind, s.status, s.title, s.content, s.decision_context, s.decision_reason,
         s.alternatives, s.tags, s.updated_at, s.score
  from scored s
  where s.score > 0
  order by s.score desc, s.updated_at desc
  limit greatest(1, least(coalesce(p_limit, 8), 30));
$$;

create or replace function public.ai_usage_summary(p_from timestamptz, p_to timestamptz)
returns table (
  day date,
  feature text,
  model text,
  runs integer,
  errors integer,
  input_tokens bigint,
  cached_input_tokens bigint,
  output_tokens bigint,
  reasoning_tokens bigint,
  web_search_calls integer,
  cost_usd numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  select (r.created_at at time zone 'Asia/Seoul')::date as day,
         r.feature,
         r.model,
         count(*)::integer as runs,
         (count(*) filter (where r.status = 'error'))::integer as errors,
         coalesce(sum(r.input_tokens), 0)::bigint,
         coalesce(sum(r.cached_input_tokens), 0)::bigint,
         coalesce(sum(r.output_tokens), 0)::bigint,
         coalesce(sum(r.reasoning_tokens), 0)::bigint,
         coalesce(sum(r.web_search_calls), 0)::integer,
         coalesce(sum(r.cost_usd), 0)::numeric
  from public.ai_runs r
  where r.created_at >= p_from
    and r.created_at < p_to
  group by 1, 2, 3
  order by 1, 2, 3;
$$;

-- 한국 시간 기준 이번 달 누적 비용
create or replace function public.ai_month_cost_usd()
returns numeric
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(sum(r.cost_usd), 0)::numeric
  from public.ai_runs r
  where r.created_at >= (date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul');
$$;

revoke all on function public.ai_search_memories(text[], integer) from public, anon;
revoke all on function public.ai_usage_summary(timestamptz, timestamptz) from public, anon;
revoke all on function public.ai_month_cost_usd() from public, anon;
grant execute on function public.ai_search_memories(text[], integer) to authenticated, service_role;
grant execute on function public.ai_usage_summary(timestamptz, timestamptz) to authenticated, service_role;
grant execute on function public.ai_month_cost_usd() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8) 첨부 파일 버킷 (비공개, 슈퍼관리자 전용). Edge Function은 서명 URL로 모델에 전달한다.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ai-attachments',
  'ai-attachments',
  false,
  20971520, -- 20MB
  array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'application/pdf']
)
on conflict (id) do nothing;

drop policy if exists "ai attachments select" on storage.objects;
create policy "ai attachments select" on storage.objects
  for select to authenticated
  using (bucket_id = 'ai-attachments' and (select public.is_superadmin()));

drop policy if exists "ai attachments insert" on storage.objects;
create policy "ai attachments insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'ai-attachments' and (select public.is_superadmin()));

drop policy if exists "ai attachments delete" on storage.objects;
create policy "ai attachments delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'ai-attachments' and (select public.is_superadmin()));

-- ---------------------------------------------------------------------------
-- 9) 초기 기억: 교육철학(docs/assessment/philosophy.md에서 옮김)과 AI의 역할
-- ---------------------------------------------------------------------------
insert into public.ai_memories (kind, status, title, content, sort_order, tags)
select 'identity', 'active', '교육철학', $philosophy$
## 한 문장 요약
교육은 학생의 능력을 재단하는 일이 아니라, 학생이 가진 능력이 **어떻게 발현되고 흔들리는지**를 정확히 이해하고 조정하는 일이다.

## 핵심 축 5가지

### 1) 점수 중심 교육의 구조적 거부
- **점수는 관측값**이다.
- 문제는 점수가 **해석 없이** 설명자가 될 때다.
- 따라서 점수를 지우지 않되, **해석 책임**을 반드시 요구한다.

### 2) 능력과 상태의 윤리적 분리
- 불안 ≠ 능력
- 행동 ≠ 능력
- 성과 ≠ 능력
학생에게 **책임을 물을 수 있는 영역**과 **물어서는 안 되는 영역**을 분리한다.

### 3) 바꿀 수 없는 것을 교육의 대상에서 제외
- 재능, 기질, 운, 환경은 **비개입 변수**다.
- 교육은 **통제 가능한 것**만 다룬다.
- 말이 아니라 **구조로 구현**한다.

### 4) 사고는 질문과 답의 연쇄
- 사고 = 질문 생성 → 답 탐색 → 검증 → 재질문
질문은 사고의 하위가 아니라 **사고를 구동하는 엔진**이다.

### 5) 학생은 유형이 아니라 좌표
- 유형화/분류/낙인을 경계한다.
- 학생은 "어떤 사람"이 아니라 "어떤 위치에 있는 상태"다.
- 변화 가능성을 항상 열어둔다.

## 핵심 키워드
**구조적 인본주의**
- 인본주의: 학생을 재단하지 않는다
- 구조적: 감정이나 선언이 아니라 구조로 구현한다

## 교육자 유형
카리스마형, 통제형, 성과 압박형, 유형 분류형이 아니라 **설계자형 교육자**.
학생을 이해하는 **좌표계** 자체를 설계한다.

## 지향점
궁극적으로는 "성적을 올리는 시스템"이 아니라, **학생을 이해하는 새로운 언어를 만드는 일**이다.
그 언어는 교사에게는 지도 기준이 되고, 학생에게는 자기 이해의 도구가 되고, 학부모에게는 설명 가능한 보고서가 된다.
$philosophy$, 0, array['교육철학']
where not exists (
  select 1 from public.ai_memories where kind = 'identity' and title = '교육철학'
);

insert into public.ai_memories (kind, status, title, content, sort_order, tags)
select 'identity', 'active', 'AI의 역할', $role$
- AI는 최종 결정을 대신하지 않는다. 관련 정보를 구조화하고 분석해서 사용자의 판단을 돕는다.
- 데이터 변경이나 중요한 결정은 초안으로 제안하고, 사용자가 확인한 뒤에만 확정한다.
- 근거가 부족하면 추측하지 말고 무엇이 더 필요한지 말한다.
$role$, 1, array['운영원칙']
where not exists (
  select 1 from public.ai_memories where kind = 'identity' and title = 'AI의 역할'
);
