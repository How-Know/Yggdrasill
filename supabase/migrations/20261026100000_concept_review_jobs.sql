-- 20261026100000: 개념 검수 작업 원장 (Think 검수 작업 대조·누락 보완, 2026-10-26)
--
-- 설계: docs/architecture/concept-library.md "개념 검수 작업"
--
-- 이미 있는 것(20261023160000): 고정 순회 목록(concept_review_walks), 범위별 검토 기록, 검토 카드(20개·항목별 승인).
-- 이 파일이 더하는 것:
-- 1) concept_review_jobs: 고정 목록 하나를 끝까지 가는 작업. 대화(conversation_id)에 묶이지 않아 새 대화에서 찾아 잇는다.
--    served_through(A, 내준 위치) · checkpoint(B, 앞에서부터 빈틈없이 상태가 저장된 위치)를 따로 둔다. 완료(C)는 저장하지 않고
--    승인된 검토 기록·카드 결과로 매번 센다. 작업이 걸린 목록은 30일 지우기에서 빠진다(목록 행 삭제도 막는다).
-- 2) concept_review_job_items: 위치마다 읽은 판·다 읽었는지·범위별 판단 초안(초안 판 draft_version)·다음 할 일·실패 이유·연결 카드.
-- 3) concept_review_job_cards: 작업이 낸 카드와 멱등 키(위치:초안 판). 같은 키·같은 내용이면 같은 카드, 같은 키·다른 내용이면 충돌.
--    카드 만들기와 연결은 한 트랜잭션이다. 예전 대기 카드는 항목이 모두 이 목록 개념일 때만 legacy 로 잇고, 아니면 충돌로 알린다.
-- 4) 임대: 한 작업은 한 실행만 쓴다. 넘겨받을 때마다 lease_gen 이 오르고, 쓰기 RPC는 모두 받은 gen 이 지금과 같은지 본다(늦은 쓰기 거부).
-- 5) 답변 뒤 자동 이어하기 관문(concept_review_job_run_gate). auto_run 기본 꺼짐이고 켜는 RPC는 두지 않는다(결정 뒤 따로 연다).
--    켜져도 판단·초안 저장·카드 제출까지만이고 승인은 사람만 한다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_review_jobs (
  id uuid primary key default gen_random_uuid(),
  walk_id uuid not null unique references public.concept_review_walks(id) on delete restrict,
  title text not null check (char_length(title) between 1 and 120),
  status text not null default 'active' check (status in ('active', 'paused', 'cancelled')),
  pause_reason text,
  total integer not null check (total >= 0),
  served_through integer not null default 0 check (served_through >= 0),
  checkpoint integer not null default 0 check (checkpoint >= 0),
  lease_holder text,
  lease_until timestamptz,
  lease_gen bigint not null default 0,
  auto_run boolean not null default false,
  limits jsonb not null default '{
    "max_runs_per_day": 6,
    "max_items_per_run": 5,
    "max_pending_cards": 3,
    "max_cost_usd_per_day": 1,
    "stop_after_idle_runs": 2
  }'::jsonb check (jsonb_typeof(limits) = 'object'),
  last_progress_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.concept_review_job_items (
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  pos integer not null check (pos >= 1),
  concept_id uuid not null,
  state text not null check (state in ('drafted', 'deferred', 'failed', 'submitted', 'reused', 'waiting', 'missing')),
  revision text,
  read_complete boolean not null default false,
  unread text,
  draft jsonb check (draft is null or jsonb_typeof(draft) = 'array'),
  draft_version integer not null default 0,
  draft_hash text,
  next_action text,
  reason text,
  action_id uuid,
  action_items integer[],
  gen bigint not null default 0,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (job_id, pos)
);

create table if not exists public.concept_review_job_cards (
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  action_id uuid not null,
  idem_key text not null,
  content_hash text not null,
  positions integer[] not null default '{}'::integer[],
  legacy boolean not null default false,
  origin_conversation_id uuid,
  moved_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (job_id, action_id),
  unique (job_id, idem_key)
);

create table if not exists public.concept_review_job_runs (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  gen bigint not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  items_saved integer,
  cards integer,
  cost_usd numeric
);

create index if not exists concept_review_job_runs_job on public.concept_review_job_runs (job_id, started_at desc);

alter table public.concept_review_jobs enable row level security;
alter table public.concept_review_job_items enable row level security;
alter table public.concept_review_job_cards enable row level security;
alter table public.concept_review_job_runs enable row level security;
revoke all on public.concept_review_jobs, public.concept_review_job_items, public.concept_review_job_cards,
  public.concept_review_job_runs from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 작업이 걸린 목록은 30일 지우기에서 뺀다 (20261023160000 정의에서 지우기 줄만 다름)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_walk(p_walk_id uuid, p_filter jsonb, p_offset integer, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_walk public.concept_review_walks;
  v_f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_folder uuid;
  v_type text;
  v_name text;
  v_placed text;
  v_review text;
  v_scope text;
  v_ids uuid[];
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 60);
  v_total integer;
  v_items jsonb;
begin
  perform public.concept_review_assert_operator();
  if p_walk_id is null then
    if jsonb_typeof(v_f) <> 'object' then
      raise exception 'concept_review_bad_filter';
    end if;
    if nullif(btrim(coalesce(v_f ->> 'folder_id', '')), '') is not null then
      v_folder := public.course_think_uuid(v_f ->> 'folder_id');
      if v_folder is null or not exists (select 1 from public.concept_categories where id = v_folder) then
        raise exception 'concept_review_folder_not_found';
      end if;
    end if;
    v_type := nullif(btrim(coalesce(v_f ->> 'type', '')), '');
    if v_type is not null and v_type <> '유형 없음'
       and not exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_type)) then
      raise exception 'concept_review_unknown_type';
    end if;
    v_name := nullif(btrim(coalesce(v_f ->> 'name', '')), '');
    if char_length(coalesce(v_name, '')) > 80 then
      raise exception 'concept_review_bad_filter';
    end if;
    v_placed := coalesce(nullif(v_f ->> 'placed', ''), 'any');
    v_review := coalesce(nullif(v_f ->> 'review', ''), 'any');
    v_scope := nullif(v_f ->> 'review_scope', '');
    if v_placed not in ('any', 'placed', 'unplaced')
       or v_review not in ('any', 'unreviewed', 'stale', 'not_current', 'has_issue', 'merge_needed')
       or (v_scope is not null and v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations')) then
      raise exception 'concept_review_bad_filter';
    end if;

    with recursive tree(id) as (
      select v_folder where v_folder is not null
      union
      select c.id from public.concept_categories c join tree t on c.parent_id = t.id
    )
    select coalesce(array_agg(x.id order by x.path, x.sort_order, x.name, x.id), '{}'::uuid[]) into v_ids
      from (
        select c.id, c.name, coalesce(c.sort_order, 0) as sort_order,
               array_to_string(public.concept_folder_path(c.main_category_id), ' › ') as path
          from public.concepts c
          left join public.concept_type_links l on l.concept_id = c.id
          left join public.concept_types t on t.id = l.type_id
         where (v_folder is null or c.main_category_id in (select id from tree))
           and (v_type is null or (v_type = '유형 없음' and t.id is null) or lower(btrim(t.name)) = lower(v_type))
           and (v_name is null or strpos(lower(c.name), lower(v_name)) > 0)
           and case v_placed
             when 'any' then true
             else (v_placed = 'placed') = exists (
               select 1
                 from public.concept_appearances a
                 join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
                 join public.course_maps m on m.id = u.course_id and m.archived_at is null
                where a.concept_id = c.id
             )
           end
           and case v_review
             when 'any' then true
             else public.concept_review_matches(public.concept_review_scope_state(c.id), v_review, v_scope)
           end
      ) x;

    delete from public.concept_review_walks w
     where w.created_at < now() - interval '30 days'
       and not exists (select 1 from public.concept_review_jobs j where j.walk_id = w.id);
    insert into public.concept_review_walks (filter, concept_ids, created_by)
    values (
      jsonb_build_object('folder_id', v_folder, 'type', v_type, 'name', v_name, 'placed', v_placed,
                         'review', v_review, 'review_scope', v_scope),
      v_ids, auth.uid()
    )
    returning * into v_walk;
  else
    select * into v_walk from public.concept_review_walks where id = p_walk_id;
    if not found then
      raise exception 'concept_review_walk_not_found';
    end if;
  end if;

  v_total := coalesce(cardinality(v_walk.concept_ids), 0);
  select coalesce(jsonb_agg(
           case when c.id is null then jsonb_build_object('id', w.id, 'missing', true)
                else public.concept_review_brief(c.id) end
           order by w.n
         ), '[]'::jsonb)
    into v_items
    from unnest(v_walk.concept_ids[v_offset + 1 : v_offset + v_limit]) with ordinality as w(id, n)
    left join public.concepts c on c.id = w.id;
  return jsonb_build_object(
    'walk_id', v_walk.id, 'started_at', v_walk.created_at, 'filter', v_walk.filter,
    'total', v_total, 'offset', v_offset, 'items', v_items,
    'next_offset', case when v_offset + v_limit < v_total then v_offset + v_limit end,
    'created_after', (select count(*) from public.concepts where created_at > v_walk.created_at)
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 도우미
-- ─────────────────────────────────────────────────────────────────────────

-- 승인을 기다리는 검토 카드에 든 개념 id.
create or replace function public.concept_review_pending_concepts()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct public.course_think_uuid(x ->> 'concept_id')), '{}'::uuid[])
    from public.ai_actions a
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
    ) x
   where a.kind = 'concept_review_record' and a.status = 'proposed';
$$;

-- 개념 하나의 검수 상태(승인된 기록 기준). missing · pending(승인 대기 카드에 있음) · no_record · recheck(최신 기록 중 내용이 바뀐 범위) ·
-- issue(지금 판의 문제 있음) · complete. complete 의 remaining 은 남은 비교·확인 못 함·병합 필요 범위다.
create or replace function public.concept_review_job_concept_state(p_concept_id uuid, p_pending uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_state jsonb;
  v_remaining jsonb;
begin
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    return jsonb_build_object('state', 'missing');
  end if;
  if p_concept_id = any (coalesce(p_pending, '{}'::uuid[])) then
    return jsonb_build_object('state', 'pending');
  end if;
  v_state := public.concept_review_scope_state(p_concept_id);
  if v_state = '{}'::jsonb then
    return jsonb_build_object('state', 'no_record');
  end if;
  if exists (select 1 from jsonb_each(v_state) e where coalesce((e.value ->> 'stale')::boolean, false)) then
    return jsonb_build_object('state', 'recheck', 'scopes', v_state);
  end if;
  if exists (select 1 from jsonb_each(v_state) e where e.value ->> 'outcome' = 'issue_found') then
    return jsonb_build_object('state', 'issue', 'scopes', v_state);
  end if;
  select coalesce(jsonb_agg(e.key order by e.key), '[]'::jsonb) into v_remaining
    from jsonb_each(v_state) e
   where e.value ->> 'outcome' in ('needs_comparison', 'unverified', 'merge_needed');
  return jsonb_build_object('state', 'complete', 'remaining', v_remaining);
end;
$$;

-- 앞에서부터 빈틈없이 상태가 저장된 위치까지 checkpoint 를 올린다.
create or replace function public.concept_review_job_advance(p_job_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_cp integer;
begin
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  select coalesce(min(g.p) - 1, v_job.total) into v_cp
    from generate_series(v_job.checkpoint + 1, v_job.total) g(p)
   where not exists (select 1 from public.concept_review_job_items i where i.job_id = p_job_id and i.pos = g.p);
  update public.concept_review_jobs
     set checkpoint = v_cp, served_through = greatest(served_through, v_cp), updated_at = now()
   where id = p_job_id;
  return v_cp;
end;
$$;

-- 쓰기 전: 운영자 · 있는 작업 · 진행 중 · 받은 gen 이 지금 임대와 같다(넘겨받은 뒤의 늦은 쓰기 거부). 임대를 늘린다.
create or replace function public.concept_review_job_lock(p_job_id uuid, p_gen bigint)
returns public.concept_review_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id for update;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  if p_gen is distinct from v_job.lease_gen then
    raise exception 'concept_review_job_lease_lost';
  end if;
  if v_job.status <> 'active' then
    raise exception 'concept_review_job_not_active';
  end if;
  update public.concept_review_jobs set lease_until = now() + interval '20 minutes' where id = p_job_id
  returning * into v_job;
  return v_job;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 찾기·시작·넘겨받기
-- ─────────────────────────────────────────────────────────────────────────

-- 새 대화에서 이어갈 작업 찾기. 아무것도 만들거나 지우지 않는다. 여러 개면 고르지 않고 모두 돌려준다.
create or replace function public.concept_review_jobs_find()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.concept_review_assert_operator();
  return jsonb_build_object(
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
               'job_id', j.id, 'title', j.title, 'status', j.status, 'pause_reason', j.pause_reason,
               'walk_id', j.walk_id, 'total', j.total, 'checkpoint', j.checkpoint, 'served_through', j.served_through,
               'created_by_me', j.created_by = auth.uid(), 'created_at', j.created_at, 'updated_at', j.updated_at,
               'last_progress_at', j.last_progress_at
             ) order by j.updated_at desc)
        from public.concept_review_jobs j
       where j.status <> 'cancelled'
    ), '[]'::jsonb),
    'walks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'walk_id', w.id, 'total', cardinality(w.concept_ids), 'filter', w.filter, 'created_at', w.created_at,
               'job_id', (select j.id from public.concept_review_jobs j where j.walk_id = w.id),
               'deleted_after', case when exists (select 1 from public.concept_review_jobs j where j.walk_id = w.id)
                                     then null else w.created_at + interval '30 days' end
             ) order by w.created_at desc)
        from (select * from public.concept_review_walks order by created_at desc limit 10) w
    ), '[]'::jsonb)
  );
end;
$$;

-- 이미 있는 목록으로 작업을 연다. 목록을 새로 만들지 않는다. 같은 목록의 작업이 있으면 그 작업을 돌려준다.
create or replace function public.concept_review_job_start(p_walk_id uuid, p_title text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_walk public.concept_review_walks;
  v_job public.concept_review_jobs;
  v_title text := btrim(coalesce(p_title, ''));
begin
  perform public.concept_review_assert_operator();
  select * into v_walk from public.concept_review_walks where id = p_walk_id for share;
  if not found then
    raise exception 'concept_review_walk_not_found';
  end if;
  select * into v_job from public.concept_review_jobs where walk_id = p_walk_id;
  if found then
    return jsonb_build_object('job_id', v_job.id, 'existing', true, 'status', v_job.status);
  end if;
  if char_length(v_title) not between 1 and 120 then
    raise exception 'concept_review_job_bad_title';
  end if;
  insert into public.concept_review_jobs (walk_id, title, total)
  values (p_walk_id, v_title, coalesce(cardinality(v_walk.concept_ids), 0))
  returning * into v_job;
  return jsonb_build_object('job_id', v_job.id, 'existing', false, 'status', v_job.status);
end;
$$;

-- p_mode take: 지금 실행이 넘겨받는다(앞 실행의 이후 쓰기는 거부된다). if_free: 임대가 비었을 때만(자동 이어하기).
-- 같은 holder 가 다시 부르면 gen 을 그대로 둔다.
create or replace function public.concept_review_job_claim(p_job_id uuid, p_holder text, p_mode text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_holder text := left(btrim(coalesce(p_holder, '')), 120);
begin
  perform public.concept_review_assert_operator();
  if v_holder = '' or p_mode not in ('take', 'if_free') then
    raise exception 'concept_review_job_bad_claim';
  end if;
  select * into v_job from public.concept_review_jobs where id = p_job_id for update;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  if v_job.status <> 'active' then
    raise exception 'concept_review_job_not_active';
  end if;
  if v_job.lease_holder = v_holder and v_job.lease_until > now() then
    update public.concept_review_jobs set lease_until = now() + interval '20 minutes' where id = p_job_id
    returning * into v_job;
  elsif p_mode = 'if_free' and v_job.lease_until > now() then
    raise exception 'concept_review_job_busy';
  else
    update public.concept_review_jobs
       set lease_holder = v_holder, lease_until = now() + interval '20 minutes', lease_gen = lease_gen + 1, updated_at = now()
     where id = p_job_id
    returning * into v_job;
  end if;
  return jsonb_build_object('gen', v_job.lease_gen, 'lease_until', v_job.lease_until);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 상태(완료 집계)
-- ─────────────────────────────────────────────────────────────────────────

-- 완료(C)는 저장값이 아니라 지금 계산한다: 승인된 기록이 지금 판과 맞고(바뀐 범위 없음) 문제 있음이 없고, 승인 대기·미결 항목이 아닌 개념.
-- 비교 필요·확인 못 함·병합 필요가 남은 개념도 완료로 세되 remaining 에 따로 센다.
create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_pending uuid[];
  v_limit integer := least(greatest(coalesce(p_open_limit, 20), 0), 60);
  v_counts jsonb := '{"complete": 0, "awaiting": 0, "drafted": 0, "open": 0, "issue": 0, "recheck": 0,
                      "not_reviewed": 0, "missing": 0, "with_remaining": 0}'::jsonb;
  v_open jsonb := '[]'::jsonb;
  v_cs jsonb;
  v_cat text;
  v_next text;
  v_total integer;
  r record;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_total := coalesce(cardinality(v_walk.concept_ids), 0);
  v_pending := public.concept_review_pending_concepts();

  for r in
    select x.pos::integer as pos, x.cid, i.state as item_state, i.next_action, i.reason, i.action_id,
           i.action_items, i.draft_version, a.id as card_id, a.status as card_status, a.result as card_result
      from unnest(v_walk.concept_ids) with ordinality as x(cid, pos)
      left join public.concept_review_job_items i on i.job_id = v_job.id and i.pos = x.pos
      left join public.ai_actions a on a.id = i.action_id
     order by x.pos
  loop
    v_cs := public.concept_review_job_concept_state(r.cid, v_pending);
    v_next := r.next_action;
    v_cat := case
      when v_cs ->> 'state' = 'missing' then 'missing'
      when r.item_state in ('deferred', 'failed') then 'open'
      when r.item_state = 'drafted' then 'drafted'
      when v_cs ->> 'state' = 'pending' then 'awaiting'
      when v_cs ->> 'state' = 'complete' then 'complete'
      when r.item_state = 'submitted' and r.card_id is null then 'open'
      when r.item_state = 'submitted' and r.card_status = 'rejected' then 'open'
      when r.item_state = 'submitted' and r.card_status = 'applied' and exists (
        select 1 from jsonb_array_elements(coalesce(r.card_result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer = any (coalesce(r.action_items, '{}'::integer[])) and e ->> 'status' <> 'applied'
      ) then 'open'
      when v_cs ->> 'state' = 'issue' then 'issue'
      when v_cs ->> 'state' = 'recheck' then 'recheck'
      else 'not_reviewed'
    end;
    if r.item_state = 'submitted' and v_cat = 'open' then
      v_next := case
        when r.card_id is null then '카드가 없어졌다(대화 삭제 등). 저장된 초안을 다시 제출한다'
        when r.card_status = 'rejected' then '거절된 카드다. 사용자 의견을 확인하고 고친 초안을 저장한다(같은 내용 재제출 안 함)'
        else '승인 때 남지 않은 항목이 있다. 다시 읽고 판단해 새 초안을 저장한다'
      end;
    elsif v_cat = 'issue' then
      v_next := '문제 있음 기록이 있다. 고치기 카드 승인 뒤 다시 확인해 기록을 남긴다';
    elsif v_cat = 'recheck' then
      v_next := '검토 뒤 내용이 바뀐 범위가 있다. 다시 읽고 확인한다';
    end if;
    v_counts := jsonb_set(v_counts, array[v_cat], to_jsonb((v_counts ->> v_cat)::integer + 1));
    if v_cat = 'complete' and jsonb_array_length(coalesce(v_cs -> 'remaining', '[]'::jsonb)) > 0 then
      v_counts := jsonb_set(v_counts, '{with_remaining}', to_jsonb((v_counts ->> 'with_remaining')::integer + 1));
    end if;
    if v_cat in ('open', 'drafted', 'issue', 'recheck') and (r.pos <= v_job.checkpoint or r.item_state is not null)
       and jsonb_array_length(v_open) < v_limit then
      v_open := v_open || jsonb_build_array(jsonb_build_object(
        'position', r.pos, 'concept_id', r.cid, 'name', (select name from public.concepts where id = r.cid),
        'category', v_cat, 'item_state', r.item_state, 'next_action', v_next, 'reason', r.reason,
        'action_id', r.action_id, 'draft_version', r.draft_version
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'job', jsonb_build_object(
      'job_id', v_job.id, 'title', v_job.title, 'status', v_job.status, 'pause_reason', v_job.pause_reason,
      'walk_id', v_job.walk_id, 'walk_created_at', v_walk.created_at, 'total', v_job.total,
      'served_through', v_job.served_through, 'checkpoint', v_job.checkpoint,
      'created_by_me', v_job.created_by = auth.uid(), 'created_at', v_job.created_at, 'updated_at', v_job.updated_at,
      'lease_active', v_job.lease_until > now(), 'auto_run', v_job.auto_run, 'limits', v_job.limits
    ),
    'walk_total', v_total,
    'total_mismatch', v_total <> v_job.total or (v_counts ->> 'missing')::integer > 0,
    'counts', v_counts,
    'progress_line', format('%s개 중 %s개 완료', v_job.total, v_counts ->> 'complete'),
    'open_items', v_open,
    'pending_cards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'action_id', a.id, 'conversation_id', a.conversation_id, 'conversation_title', c.title,
               'created_at', a.created_at, 'items', jsonb_array_length(coalesce(a.payload -> 'items', '[]'::jsonb)),
               'linked', jc.action_id is not null, 'legacy', coalesce(jc.legacy, false)
             ) order by a.created_at)
        from public.ai_actions a
        left join public.ai_conversations c on c.id = a.conversation_id
        left join public.concept_review_job_cards jc on jc.job_id = v_job.id and jc.action_id = a.id
       where a.kind = 'concept_review_record' and a.status = 'proposed'
         and (jc.action_id is not null or exists (
           select 1 from jsonb_array_elements(
             case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
           ) x where public.course_think_uuid(x ->> 'concept_id') = any (v_walk.concept_ids)
         ))
    ), '[]'::jsonb)
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 다음 묶음·저장
-- ─────────────────────────────────────────────────────────────────────────

-- checkpoint 다음부터 상태가 없는 위치를 p_count(1~10)개 내준다. 앞서 내줬지만 저장되지 않은 위치가 먼저 나온다.
-- 이미 완료인 개념은 reused, 지워진 개념은 missing, 승인 대기 카드에 든 개념은 waiting 으로 저장하고 넘어간다(판단은 하지 않는다).
create or replace function public.concept_review_job_next(p_job_id uuid, p_gen bigint, p_count integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_count integer := least(greatest(coalesce(p_count, 5), 1), 10);
  v_pending uuid[];
  v_pos integer;
  v_cid uuid;
  v_cs jsonb;
  v_batch jsonb := '[]'::jsonb;
  v_auto jsonb := '{"reused": 0, "missing": 0, "waiting": 0}'::jsonb;
  v_scanned integer := 0;
  v_state text;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_pending := public.concept_review_pending_concepts();
  v_pos := v_job.checkpoint;
  while v_pos < v_job.total and jsonb_array_length(v_batch) < v_count and v_scanned < 60 loop
    v_pos := v_pos + 1;
    continue when exists (select 1 from public.concept_review_job_items where job_id = p_job_id and pos = v_pos);
    v_scanned := v_scanned + 1;
    v_cid := v_walk.concept_ids[v_pos];
    v_cs := public.concept_review_job_concept_state(v_cid, v_pending);
    v_state := case v_cs ->> 'state' when 'missing' then 'missing' when 'complete' then 'reused' when 'pending' then 'waiting' end;
    if v_state is not null then
      insert into public.concept_review_job_items (job_id, pos, concept_id, state, revision, reason, next_action, gen)
      values (
        p_job_id, v_pos, v_cid, v_state,
        public.concept_review_revision(public.concept_review_marks(v_cid)),
        case v_state when 'missing' then '목록을 만든 뒤 지워진 개념'
                     when 'reused' then '지금 판과 맞는 승인된 검토 기록이 있다'
                     else '승인을 기다리는 검토 카드에 이미 들어 있다' end,
        case v_state when 'waiting' then '그 카드의 승인 결과를 본다' end,
        v_job.lease_gen
      );
      v_auto := jsonb_set(v_auto, array[v_state], to_jsonb((v_auto ->> v_state)::integer + 1));
    else
      v_batch := v_batch || jsonb_build_array(jsonb_build_object(
        'position', v_pos, 'concept_id', v_cid, 'state', v_cs ->> 'state', 'concept', public.concept_review_brief(v_cid)
      ));
    end if;
  end loop;
  update public.concept_review_jobs
     set served_through = greatest(served_through, v_pos), updated_at = now(),
         last_progress_at = case when v_auto <> '{"reused": 0, "missing": 0, "waiting": 0}'::jsonb then now() else last_progress_at end
   where id = p_job_id;
  perform public.concept_review_job_advance(p_job_id);
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  return jsonb_build_object(
    'batch', v_batch, 'auto_saved', v_auto, 'checkpoint', v_job.checkpoint, 'served_through', v_job.served_through,
    'total', v_job.total, 'reached_end', v_pos >= v_job.total
  );
end;
$$;

-- 위치별 상태 저장(10개까지). 항목마다 따로 저장·거부한다.
-- p_items [{position, concept_id, state: drafted|deferred|failed, revision, read_complete, unread, reviews, next_action, reason, rework}]
-- reviews [{scope, outcome, checked, findings, basis, unverified, follow_up, compared_ids, to_compare_ids}] (drafted 만, 범위 1~5개)
create or replace function public.concept_review_job_save(p_job_id uuid, p_gen bigint, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_e jsonb;
  v_r jsonb;
  v_pos integer;
  v_cid uuid;
  v_state text;
  v_prev public.concept_review_job_items;
  v_card public.ai_actions;
  v_marks jsonb;
  v_rev text;
  v_draft jsonb;
  v_scopes text[];
  v_scope text;
  v_outcome text;
  v_hash text;
  v_rework boolean;
  v_next text;
  v_reason text;
  v_unread text;
  v_complete boolean;
  v_version integer;
  v_out jsonb := '[]'::jsonb;
  v_saved integer := 0;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if jsonb_array_length(p_items) > 10 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;

  for v_e in select e from jsonb_array_elements(p_items) e loop
    v_pos := null;
    begin
      if jsonb_typeof(v_e) <> 'object' then
        raise exception 'concept_review_job_bad_item';
      end if;
      v_pos := case when jsonb_typeof(v_e -> 'position') = 'number' then (v_e ->> 'position')::integer end;
      if v_pos is null or v_pos < 1 or v_pos > v_job.total then
        raise exception 'concept_review_job_bad_position';
      end if;
      v_cid := public.course_think_uuid(v_e ->> 'concept_id');
      if v_cid is distinct from v_walk.concept_ids[v_pos] then
        raise exception 'concept_review_job_wrong_concept';
      end if;
      if v_pos > v_job.served_through and not exists (
        select 1 from public.concept_review_job_items where job_id = p_job_id and pos = v_pos
      ) then
        raise exception 'concept_review_job_not_served';
      end if;
      v_state := v_e ->> 'state';
      if v_state is null or v_state not in ('drafted', 'deferred', 'failed') then
        raise exception 'concept_review_job_bad_state';
      end if;
      v_rework := coalesce((v_e ->> 'rework')::boolean, false);
      v_next := nullif(left(btrim(coalesce(v_e ->> 'next_action', '')), 300), '');
      v_reason := nullif(left(btrim(coalesce(v_e ->> 'reason', '')), 500), '');
      v_unread := nullif(left(btrim(coalesce(v_e ->> 'unread', '')), 500), '');
      v_complete := coalesce((v_e ->> 'read_complete')::boolean, false);
      if not exists (select 1 from public.concepts where id = v_cid) then
        raise exception 'concept_review_concept_not_found';
      end if;
      v_marks := public.concept_review_marks(v_cid);

      select * into v_prev from public.concept_review_job_items where job_id = p_job_id and pos = v_pos for update;
      v_card := null;
      if found and v_prev.action_id is not null then
        select * into v_card from public.ai_actions where id = v_prev.action_id;
      end if;
      if v_prev.state in ('submitted', 'waiting') and (
           v_card.status = 'proposed' or (v_prev.state = 'waiting' and v_cid = any (public.concept_review_pending_concepts()))
         ) then
        raise exception 'concept_review_job_item_pending';
      end if;
      if v_prev.state in ('reused', 'submitted') and not v_rework
         and public.concept_review_job_concept_state(v_cid, '{}'::uuid[]) ->> 'state' = 'complete' then
        raise exception 'concept_review_job_item_done';
      end if;

      v_draft := v_prev.draft;
      v_rev := v_prev.revision;
      if v_state = 'drafted' then
        if not v_complete then
          raise exception 'concept_review_job_read_incomplete';
        end if;
        if jsonb_typeof(v_e -> 'reviews') <> 'array' or jsonb_array_length(v_e -> 'reviews') not between 1 and 5 then
          raise exception 'concept_review_job_bad_reviews';
        end if;
        v_rev := btrim(coalesce(v_e ->> 'revision', ''));
        v_scopes := '{}'::text[];
        v_draft := '[]'::jsonb;
        for v_r in select x from jsonb_array_elements(v_e -> 'reviews') x loop
          v_scope := v_r ->> 'scope';
          v_outcome := v_r ->> 'outcome';
          if v_scope is null or v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations') then
            raise exception 'concept_review_bad_scope';
          end if;
          if v_scope = any (v_scopes) then
            raise exception 'concept_review_duplicate';
          end if;
          v_scopes := v_scopes || v_scope;
          if v_outcome is null or v_outcome not in ('no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed') then
            raise exception 'concept_review_bad_outcome';
          end if;
          if v_outcome = 'merge_needed' and v_scope <> 'unit' then
            raise exception 'concept_review_merge_scope';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) is null then
            raise exception 'concept_review_revision_required';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) <> left(v_marks ->> public.concept_review_scope_mark(v_scope), 12) then
            raise exception 'concept_review_stale';
          end if;
          v_draft := v_draft || jsonb_build_array(jsonb_build_object(
            'concept_id', v_cid, 'revision', v_rev, 'scope', v_scope, 'outcome', v_outcome,
            'checked', public.concept_review_text(v_r ->> 'checked', 1000, true),
            'findings', public.concept_review_text(v_r ->> 'findings', 2000, true),
            'basis', public.concept_review_text(v_r ->> 'basis', 1000, true),
            'unverified', public.concept_review_text(v_r ->> 'unverified', 1000, false),
            'follow_up', public.concept_review_text(v_r ->> 'follow_up', 1000, false),
            'compared_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(public.concept_review_refs(v_r -> 'compared_ids', v_cid)) c
            ), '[]'::jsonb),
            'to_compare_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(public.concept_review_refs(v_r -> 'to_compare_ids', v_cid)) c
            ), '[]'::jsonb),
            'compared_text', coalesce((
              select jsonb_object_agg(c ->> 'id', c ->> 'text')
                from jsonb_array_elements(public.concept_review_refs(v_r -> 'compared_ids', v_cid)) c
            ), '{}'::jsonb)
          ));
        end loop;
      else
        if v_next is null or v_reason is null then
          raise exception 'concept_review_job_next_required';
        end if;
      end if;

      v_hash := md5(jsonb_build_array(v_state, v_rev, v_draft, v_next, v_reason, v_unread, v_complete)::text);
      if v_prev.pos is not null and v_prev.draft_hash = v_hash and v_prev.state = v_state then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'position', v_pos, 'status', 'unchanged', 'draft_version', v_prev.draft_version
        ));
        continue;
      end if;
      if v_prev.pos is not null and v_card.status = 'rejected' and not v_rework
         and v_draft is not distinct from v_prev.draft then
        raise exception 'concept_review_job_same_as_rejected';
      end if;
      v_version := case
        when v_prev.pos is null then case when v_state = 'drafted' then 1 else 0 end
        when v_draft is distinct from v_prev.draft or v_rework or v_prev.state in ('submitted', 'failed', 'waiting')
          then v_prev.draft_version + 1
        else v_prev.draft_version
      end;

      insert into public.concept_review_job_items (
        job_id, pos, concept_id, state, revision, read_complete, unread, draft, draft_version, draft_hash,
        next_action, reason, action_id, action_items, gen, updated_by, updated_at
      )
      values (
        p_job_id, v_pos, v_cid, v_state, v_rev, v_complete, v_unread, v_draft, v_version, v_hash,
        v_next, v_reason, null, null, v_job.lease_gen, auth.uid(), now()
      )
      on conflict (job_id, pos) do update
        set state = excluded.state, revision = excluded.revision, read_complete = excluded.read_complete,
            unread = excluded.unread, draft = excluded.draft, draft_version = excluded.draft_version,
            draft_hash = excluded.draft_hash, next_action = excluded.next_action, reason = excluded.reason,
            action_id = case when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                             then null else concept_review_job_items.action_id end,
            action_items = case when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                                then null else concept_review_job_items.action_items end,
            gen = excluded.gen, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
      v_saved := v_saved + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object('position', v_pos, 'status', 'saved', 'draft_version', v_version));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'position', v_pos, 'status', 'error', 'code', left(sqlerrm, 200)
      ));
    end;
  end loop;

  if v_saved > 0 then
    update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  end if;
  return jsonb_build_object('items', v_out, 'saved', v_saved, 'checkpoint', public.concept_review_job_advance(p_job_id));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 제출(멱등)·카드 가져오기
-- ─────────────────────────────────────────────────────────────────────────

-- drafted 위치를 순서대로 모아 검토 카드 한 장을 낸다(검토 20개·내용 45000바이트까지, 위치 하나는 나누지 않는다).
-- 낼 때 판이 바뀌었거나 비교한 개념이 바뀐 위치는 failed 로 돌리고, 같은 범위가 다른 대기 카드에 있으면 그대로 둔다.
-- 멱등 키 = 작업 + 위치:초안 판. 같은 키·같은 내용이면 이미 낸 카드를 돌려주고, 같은 키·다른 내용이면 충돌이다.
create or replace function public.concept_review_job_submit(p_job_id uuid, p_gen bigint, p_conversation_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_max_pending integer;
  v_it public.concept_review_job_items;
  v_r jsonb;
  v_marks jsonb;
  v_bad text;
  v_items jsonb := '[]'::jsonb;
  v_add jsonb;
  v_positions integer[] := '{}'::integer[];
  v_versions text[] := '{}'::text[];
  v_map jsonb := '{}'::jsonb;
  v_failed jsonb := '[]'::jsonb;
  v_blocked jsonb := '[]'::jsonb;
  v_key text;
  v_hash text;
  v_link public.concept_review_job_cards;
  v_act public.ai_actions;
  v_pos integer;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if v_reason = '' then
    raise exception 'course_think_reason_required';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_max_pending := coalesce((v_job.limits ->> 'max_pending_cards')::integer, 3);
  if (select count(*) from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
       where jc.job_id = p_job_id and a.status = 'proposed') >= v_max_pending then
    raise exception 'concept_review_job_pending_full';
  end if;

  for v_it in select * from public.concept_review_job_items where job_id = p_job_id and state = 'drafted' order by pos for update loop
    v_bad := null;
    v_marks := public.concept_review_marks(v_it.concept_id);
    if v_marks is null then
      v_bad := 'concept_review_concept_not_found';
    end if;
    for v_r in select x from jsonb_array_elements(v_it.draft) x loop
      exit when v_bad is not null;
      if public.concept_review_revision_part(v_r ->> 'revision', v_r ->> 'scope')
         <> left(v_marks ->> public.concept_review_scope_mark(v_r ->> 'scope'), 12) then
        v_bad := 'concept_review_stale';
      elsif exists (
        select 1 from jsonb_each_text(coalesce(v_r -> 'compared_text', '{}'::jsonb)) c
         where public.concept_review_text_mark(c.key::uuid) is distinct from c.value
      ) then
        v_bad := 'concept_review_compared_changed';
      end if;
    end loop;
    if v_bad is not null then
      update public.concept_review_job_items
         set state = 'failed', reason = v_bad, next_action = '다시 읽고 판단해 새 초안을 저장한다', updated_at = now(), gen = v_job.lease_gen
       where job_id = p_job_id and pos = v_it.pos;
      v_failed := v_failed || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', v_bad));
      continue;
    end if;
    if exists (
      select 1
        from public.ai_actions a
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
        ) x
        join jsonb_array_elements(v_it.draft) d on d ->> 'scope' = x ->> 'scope'
       where a.kind = 'concept_review_record' and a.status = 'proposed' and x ->> 'concept_id' = v_it.concept_id::text
    ) then
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', 'pending_elsewhere'));
      continue;
    end if;
    select coalesce(jsonb_agg(d - 'compared_text'), '[]'::jsonb) into v_add from jsonb_array_elements(v_it.draft) d;
    exit when jsonb_array_length(v_items) + jsonb_array_length(v_add) > 20
           or octet_length((v_items || v_add)::text) > 45000;
    v_map := v_map || jsonb_build_object(v_it.pos::text, (
      select jsonb_agg(jsonb_array_length(v_items) + n) from generate_series(1, jsonb_array_length(v_add)) n
    ));
    v_items := v_items || v_add;
    v_positions := v_positions || v_it.pos;
    v_versions := v_versions || (v_it.pos || ':' || v_it.draft_version);
  end loop;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('submitted', false, 'failed', v_failed, 'blocked', v_blocked);
  end if;

  v_key := md5(p_job_id::text || '|' || array_to_string(v_versions, ','));
  v_hash := md5(v_items::text);
  select * into v_link from public.concept_review_job_cards where job_id = p_job_id and idem_key = v_key;
  if found then
    if v_link.content_hash <> v_hash then
      raise exception 'concept_review_job_conflict';
    end if;
    select * into v_act from public.ai_actions where id = v_link.action_id;
    return jsonb_build_object('submitted', true, 'existing', true, 'action', to_jsonb(v_act),
                              'positions', to_jsonb(v_link.positions), 'failed', v_failed, 'blocked', v_blocked);
  end if;

  v_act := public.course_think_propose_review(p_conversation_id, jsonb_build_object('items', v_items, 'reason', v_reason), v_reason);
  insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
  values (p_job_id, v_act.id, v_key, v_hash, v_positions, p_conversation_id);
  foreach v_pos in array v_positions loop
    update public.concept_review_job_items
       set state = 'submitted', action_id = v_act.id,
           action_items = array(select (x #>> '{}')::integer from jsonb_array_elements(v_map -> v_pos::text) x),
           gen = v_job.lease_gen, updated_at = now()
     where job_id = p_job_id and pos = v_pos;
  end loop;
  update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  return jsonb_build_object('submitted', true, 'existing', false, 'action', to_jsonb(v_act),
                            'positions', to_jsonb(v_positions), 'failed', v_failed, 'blocked', v_blocked);
end;
$$;

-- 이 작업의 승인 대기 카드를 지금 대화로 옮겨 여기서 승인할 수 있게 한다. 카드 내용·상태·승인 이력은 그대로다.
-- 아직 이어지지 않은 예전 대기 카드는 항목이 모두 이 목록 개념일 때만 legacy 로 잇고, 섞였으면 conflicts 로 알리고 건드리지 않는다.
create or replace function public.concept_review_job_cards_here(p_job_id uuid, p_gen bigint, p_conversation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_a public.ai_actions;
  v_ids uuid[];
  v_moved jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;
  v_linked boolean;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  for v_a in
    select * from public.ai_actions a
     where a.kind = 'concept_review_record' and a.status = 'proposed'
     order by a.created_at
     for update
  loop
    v_ids := array(
      select public.course_think_uuid(x ->> 'concept_id')
        from jsonb_array_elements(case when jsonb_typeof(v_a.payload -> 'items') = 'array' then v_a.payload -> 'items' else '[]'::jsonb end) x
    );
    v_linked := exists (select 1 from public.concept_review_job_cards where job_id = p_job_id and action_id = v_a.id);
    if not v_linked then
      continue when not (v_ids && v_walk.concept_ids);
      if not (v_ids <@ v_walk.concept_ids) or exists (
        select 1 from public.concept_review_job_cards where action_id = v_a.id and job_id <> p_job_id
      ) then
        v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
          'action_id', v_a.id, 'conversation_id', v_a.conversation_id, 'reason', '목록 밖 개념이 섞였거나 다른 작업의 카드'
        ));
        continue;
      end if;
      insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, legacy, origin_conversation_id)
      values (
        p_job_id, v_a.id, 'legacy:' || v_a.id, md5(coalesce(v_a.payload -> 'items', '[]'::jsonb)::text),
        array(select x.n::integer from unnest(v_walk.concept_ids) with ordinality x(id, n) where x.id = any (v_ids) order by x.n),
        true, v_a.conversation_id
      );
    end if;
    if v_a.conversation_id <> p_conversation_id then
      update public.concept_review_job_cards
         set origin_conversation_id = coalesce(origin_conversation_id, v_a.conversation_id), moved_at = now()
       where job_id = p_job_id and action_id = v_a.id;
      update public.ai_actions set conversation_id = p_conversation_id, message_id = null where id = v_a.id
      returning * into v_a;
    end if;
    v_moved := v_moved || jsonb_build_array(to_jsonb(v_a));
  end loop;
  return jsonb_build_object('cards', v_moved, 'conflicts', v_conflicts);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8) 멈춤·다시 시작·그만두기
-- ─────────────────────────────────────────────────────────────────────────

-- 멈추거나 그만두면 임대를 끊는다(gen 이 올라 진행 중인 실행의 이후 쓰기는 거부된다). 아무것도 지우지 않는다.
create or replace function public.concept_review_job_control(p_job_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id for update;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  if p_action = 'pause' and v_job.status = 'active' then
    update public.concept_review_jobs
       set status = 'paused', pause_reason = 'user', lease_holder = null, lease_until = null, lease_gen = lease_gen + 1,
           updated_at = now()
     where id = p_job_id returning * into v_job;
  elsif p_action = 'resume' and v_job.status = 'paused' then
    update public.concept_review_jobs set status = 'active', pause_reason = null, updated_at = now()
     where id = p_job_id returning * into v_job;
  elsif p_action = 'cancel' and v_job.status <> 'cancelled' then
    update public.concept_review_jobs
       set status = 'cancelled', auto_run = false, lease_holder = null, lease_until = null, lease_gen = lease_gen + 1,
           updated_at = now()
     where id = p_job_id returning * into v_job;
  elsif p_action not in ('pause', 'resume', 'cancel') then
    raise exception 'concept_review_job_bad_action';
  else
    raise exception 'concept_review_job_bad_transition';
  end if;
  return jsonb_build_object('job_id', v_job.id, 'status', v_job.status);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9) 답변 뒤 자동 이어하기 관문 (기본 꺼짐)
-- ─────────────────────────────────────────────────────────────────────────

-- 켜져 있고 한도 안일 때만 실행을 하나 열고 임대를 넘겨받는다. 남은 위치가 없거나, 하루 실행·비용 한도, 대기 카드 한도에 걸리면 막는다.
-- 앞선 실행 stop_after_idle_runs 번이 연달아 아무것도 저장·제출하지 못했으면 작업을 멈춘다(no_progress).
create or replace function public.concept_review_job_run_gate(p_job_id uuid, p_holder text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_idle integer;
  v_claim jsonb;
  v_run uuid;
  v_block text;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id for update;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  v_idle := coalesce((v_job.limits ->> 'stop_after_idle_runs')::integer, 2);
  v_block := case
    when not v_job.auto_run then 'auto_run_off'
    when v_job.status <> 'active' then 'not_active'
    when v_job.checkpoint >= v_job.total then 'reached_end'
    when (select count(*) from public.concept_review_job_runs where job_id = p_job_id and started_at > now() - interval '1 day')
         >= coalesce((v_job.limits ->> 'max_runs_per_day')::integer, 6) then 'daily_runs'
    when (select coalesce(sum(cost_usd), 0) from public.concept_review_job_runs where job_id = p_job_id and started_at > now() - interval '1 day')
         >= coalesce((v_job.limits ->> 'max_cost_usd_per_day')::numeric, 1) then 'daily_cost'
    when (select count(*) from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
           where jc.job_id = p_job_id and a.status = 'proposed') >= coalesce((v_job.limits ->> 'max_pending_cards')::integer, 3)
      then 'pending_cards'
  end;
  if v_block is null and v_idle > 0 and (
    select count(*) = v_idle and bool_and(coalesce(items_saved, 0) = 0 and coalesce(cards, 0) = 0)
      from (select * from public.concept_review_job_runs where job_id = p_job_id and finished_at is not null
             order by started_at desc limit v_idle) x
  ) then
    update public.concept_review_jobs
       set status = 'paused', pause_reason = 'no_progress', lease_holder = null, lease_until = null, lease_gen = lease_gen + 1,
           updated_at = now()
     where id = p_job_id;
    v_block := 'no_progress';
  end if;
  if v_block is not null then
    return jsonb_build_object('allowed', false, 'reason', v_block);
  end if;
  v_claim := public.concept_review_job_claim(p_job_id, p_holder, 'if_free');
  insert into public.concept_review_job_runs (job_id, gen) values (p_job_id, (v_claim ->> 'gen')::bigint) returning id into v_run;
  return jsonb_build_object('allowed', true, 'run_id', v_run, 'gen', (v_claim ->> 'gen')::bigint,
                            'max_items', coalesce((v_job.limits ->> 'max_items_per_run')::integer, 5));
end;
$$;

create or replace function public.concept_review_job_run_finish(p_run_id uuid, p_cost_usd numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run public.concept_review_job_runs;
begin
  perform public.concept_review_assert_operator();
  select * into v_run from public.concept_review_job_runs where id = p_run_id for update;
  if not found or v_run.finished_at is not null then
    return;
  end if;
  update public.concept_review_job_runs
     set finished_at = now(), cost_usd = greatest(coalesce(p_cost_usd, 0), 0),
         items_saved = (select count(*) from public.concept_review_job_items
                         where job_id = v_run.job_id and gen = v_run.gen and updated_at >= v_run.started_at
                           and state in ('drafted', 'deferred', 'failed')),
         cards = (select count(*) from public.concept_review_job_cards
                   where job_id = v_run.job_id and created_at >= v_run.started_at and not legacy)
   where id = p_run_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 10) 기능 확인 (20261024100000 정의에 concept_review_jobs 추가)
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.ai_think_db_features()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'conversation_split',
    case
      when to_regprocedure('public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean)') is not null
       and to_regprocedure('public.ai_conversation_split_apply(uuid, jsonb)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'split_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'source_message_id' and not attisdropped
       )
      then 1
      else 0
    end,
    'think_roles',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'think_role_id' and not attisdropped
       )
       and to_regprocedure('public.ai_conversation_set_think_role(uuid, text, text[], text)') is not null
       and to_regprocedure('public.ai_search_memories_scoped(text[], integer, text, text[], uuid[])') is not null
       and to_regclass('public.ai_conversation_memory_links') is not null
       and to_regclass('public.ai_conversation_document_links') is not null
       and to_regclass('public.ai_message_context_snapshots') is not null
      then 1
      else 0
    end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
      then 1
      else 0
    end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1
      else 0
    end,
    'auto_organize',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'marked_important' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'progress_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_platform_settings'::regclass and attname = 'auto_organize_enabled' and not attisdropped
       )
       and to_regclass('public.ai_department_criteria') is not null
       and to_regprocedure('public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean)') is not null
       and to_regprocedure('public.ai_importance_mark_propose(uuid, uuid[], text, boolean)') is not null
       and to_regprocedure('public.ai_progress_summary_propose(uuid, jsonb, text, uuid)') is not null
       and to_regprocedure('public.ai_department_criteria_propose(uuid, text, jsonb, text)') is not null
       and to_regprocedure('public.ai_department_criteria_save(text, jsonb, integer)') is not null
       and to_regprocedure('public.ai_action_apply_batch(jsonb)') is not null
      then 1
      else 0
    end,
    'course_map_actions',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_appearances'::regclass and attname = 'course_unit_id' and not attisdropped
       )
       and to_regprocedure('public.course_think_action_propose(uuid, text, jsonb)') is not null
       and to_regprocedure('public.course_think_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.course_map_placements(uuid)') is not null
       and to_regprocedure('public.concept_placement_candidates(uuid, text, text, integer, integer)') is not null
       and to_regprocedure('public.concept_think_detail(uuid)') is not null
      then 1
      else 0
    end,
    'concept_review',
    case
      when to_regclass('public.concept_quality_reviews') is not null
       and to_regclass('public.concept_review_walks') is not null
       and to_regprocedure('public.concept_review_walk(uuid, jsonb, integer, integer)') is not null
       and to_regprocedure('public.concept_review_status(uuid[])') is not null
       and to_regprocedure('public.course_think_propose_review(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_review(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_relations'::regclass and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_source_pages',
    case
      when to_regclass('public.concept_source_page_images') is not null
       and to_regclass('public.concept_source_page_workers') is not null
       and to_regprocedure('public.concept_source_list(uuid)') is not null
       and to_regprocedure('public.concept_source_page_context(uuid, integer)') is not null
       and to_regprocedure('public.concept_source_page_image(uuid, integer, boolean)') is not null
      then 1
      else 0
    end,
    'concept_review_jobs',
    case
      when to_regclass('public.concept_review_jobs') is not null
       and to_regclass('public.concept_review_job_items') is not null
       and to_regclass('public.concept_review_job_cards') is not null
       and to_regprocedure('public.concept_review_jobs_find()') is not null
       and to_regprocedure('public.concept_review_job_claim(uuid, text, text)') is not null
       and to_regprocedure('public.concept_review_job_status(uuid, integer)') is not null
       and to_regprocedure('public.concept_review_job_next(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_save(uuid, bigint, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_submit(uuid, bigint, uuid, text)') is not null
       and to_regprocedure('public.concept_review_job_cards_here(uuid, bigint, uuid)') is not null
      then 1
      else 0
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 11) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_review_pending_concepts() from public, anon, authenticated;
revoke all on function public.concept_review_job_concept_state(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.concept_review_job_advance(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_job_lock(uuid, bigint) from public, anon, authenticated;

revoke all on function public.concept_review_jobs_find() from public, anon;
revoke all on function public.concept_review_job_start(uuid, text) from public, anon;
revoke all on function public.concept_review_job_claim(uuid, text, text) from public, anon;
revoke all on function public.concept_review_job_status(uuid, integer) from public, anon;
revoke all on function public.concept_review_job_next(uuid, bigint, integer) from public, anon;
revoke all on function public.concept_review_job_save(uuid, bigint, jsonb) from public, anon;
revoke all on function public.concept_review_job_submit(uuid, bigint, uuid, text) from public, anon;
revoke all on function public.concept_review_job_cards_here(uuid, bigint, uuid) from public, anon;
revoke all on function public.concept_review_job_control(uuid, text) from public, anon;
revoke all on function public.concept_review_job_run_gate(uuid, text) from public, anon;
revoke all on function public.concept_review_job_run_finish(uuid, numeric) from public, anon;

grant execute on function public.concept_review_jobs_find() to authenticated;
grant execute on function public.concept_review_job_start(uuid, text) to authenticated;
grant execute on function public.concept_review_job_claim(uuid, text, text) to authenticated;
grant execute on function public.concept_review_job_status(uuid, integer) to authenticated;
grant execute on function public.concept_review_job_next(uuid, bigint, integer) to authenticated;
grant execute on function public.concept_review_job_save(uuid, bigint, jsonb) to authenticated;
grant execute on function public.concept_review_job_submit(uuid, bigint, uuid, text) to authenticated;
grant execute on function public.concept_review_job_cards_here(uuid, bigint, uuid) to authenticated;
grant execute on function public.concept_review_job_control(uuid, text) to authenticated;
grant execute on function public.concept_review_job_run_gate(uuid, text) to authenticated;
grant execute on function public.concept_review_job_run_finish(uuid, numeric) to authenticated;

notify pgrst, 'reload schema';
