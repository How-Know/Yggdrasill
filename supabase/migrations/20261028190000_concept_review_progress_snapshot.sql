-- 검수 진행률은 조회 때 목록 전체를 다시 판정하지 않고, 저장된 위치 판정과 집계만 읽는다.
-- 원본이 바뀌면 그 트랜잭션에서 영향 받는 위치만 다시 계산할 대상으로 표시한다.
-- 초기 구축·전수 재구축·변경분 갱신은 요청이 끝나도 남는 실행 행으로 구간을 이어 간다.
-- 집계 실행은 새 판단을 하지 않고, 카드를 만들거나 승인하지 않으며, 검수 순서와 작업 상태를 바꾸지 않는다.
-- 판단 지시(review-batch)는 바꾸지 않는다. 통합 완료와 1차 검수 3조건 동시 충족의 기준도 바꾸지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 저장
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_review_progress_jobs (
  job_id uuid primary key references public.concept_review_jobs(id) on delete cascade,
  input_version bigint not null default 0,
  published_input_version bigint,
  needs_rebuild boolean not null default false,
  active_run_id uuid,
  counts jsonb,
  conditions jsonb,
  first_pass jsonb,
  progress_line text,
  condition_line text,
  first_pass_line text,
  total_mismatch boolean,
  last_success jsonb,
  last_success_at timestamptz,
  progress_error text,
  updated_at timestamptz not null default now()
);

create table if not exists public.concept_review_progress_runs (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  kind text not null check (kind in ('rebuild', 'partial', 'resummarize')),
  input_version bigint not null,
  state text not null check (state in ('running', 'published', 'superseded', 'failed')),
  cursor_pos integer not null default 1,
  attempts integer not null default 0,
  error text,
  next_attempt_at timestamptz,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists concept_review_progress_runs_job_idx
  on public.concept_review_progress_runs (job_id, state, started_at desc);

alter table public.concept_review_progress_jobs
  drop constraint if exists concept_review_progress_jobs_run_fk;
alter table public.concept_review_progress_jobs
  add constraint concept_review_progress_jobs_run_fk
  foreign key (active_run_id) references public.concept_review_progress_runs(id) on delete set null;

create table if not exists public.concept_review_progress_positions (
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  pos integer not null check (pos > 0),
  concept_id uuid,
  category text not null,
  cond_text boolean not null default false,
  cond_foundation boolean not null default false,
  cond_placement boolean not null default false,
  first_pass boolean not null default false,
  open_payload jsonb,
  dirty_token bigint not null default 0,
  published_token bigint not null default 0,
  primary key (job_id, pos)
);

create index if not exists concept_review_progress_positions_dirty_idx
  on public.concept_review_progress_positions (job_id, pos)
  where dirty_token > published_token;

create table if not exists public.concept_review_progress_stage (
  run_id uuid not null references public.concept_review_progress_runs(id) on delete cascade,
  pos integer not null check (pos > 0),
  concept_id uuid,
  category text not null,
  cond_text boolean not null default false,
  cond_foundation boolean not null default false,
  cond_placement boolean not null default false,
  first_pass boolean not null default false,
  open_payload jsonb,
  primary key (run_id, pos)
);

-- 비교 근거로 쓴 개념 → 그 판정이 있는 작업 위치. 관계의 한 다리는 관계 표에서 바로 찾는다.
create table if not exists public.concept_review_progress_deps (
  job_id uuid not null references public.concept_review_jobs(id) on delete cascade,
  pos integer not null,
  concept_id uuid not null,
  reason text not null check (reason in ('self', 'relation', 'compared')),
  primary key (job_id, pos, concept_id, reason)
);

create index if not exists concept_review_progress_deps_concept_idx
  on public.concept_review_progress_deps (concept_id, job_id, pos);

create table if not exists public.concept_review_progress_queue (
  job_id uuid primary key references public.concept_review_jobs(id) on delete cascade,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  last_error text
);

create index if not exists concept_review_walks_concept_ids_gin
  on public.concept_review_walks using gin (concept_ids);

alter table public.concept_review_progress_jobs enable row level security;
alter table public.concept_review_progress_runs enable row level security;
alter table public.concept_review_progress_positions enable row level security;
alter table public.concept_review_progress_stage enable row level security;
alter table public.concept_review_progress_deps enable row level security;
alter table public.concept_review_progress_queue enable row level security;

revoke all on public.concept_review_progress_jobs from public, anon, authenticated, service_role;
revoke all on public.concept_review_progress_runs from public, anon, authenticated, service_role;
revoke all on public.concept_review_progress_positions from public, anon, authenticated, service_role;
revoke all on public.concept_review_progress_stage from public, anon, authenticated, service_role;
revoke all on public.concept_review_progress_deps from public, anon, authenticated, service_role;
revoke all on public.concept_review_progress_queue from public, anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 가벼운 표시. 트리거 안에서는 판정·지문·외부 호출을 하지 않는다.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_progress_bump(p_jobs uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_jobs is null or cardinality(p_jobs) = 0 then
    return;
  end if;
  insert into public.concept_review_progress_jobs (job_id, input_version)
  select distinct u.id, 1 from unnest(p_jobs) as u(id) where u.id is not null
  on conflict (job_id) do update
    set input_version = public.concept_review_progress_jobs.input_version + 1,
        progress_error = null,
        updated_at = now();
  insert into public.concept_review_progress_queue (job_id)
  select distinct u.id from unnest(p_jobs) as u(id) where u.id is not null
  on conflict (job_id) do update
    set enqueued_at = now(), attempts = 0, next_attempt_at = null, last_error = null;
  update public.concept_review_progress_runs r
     set state = 'superseded', finished_at = now()
   where r.job_id = any (p_jobs) and r.state = 'failed';
  update public.concept_review_progress_jobs p
     set active_run_id = null
   where p.job_id = any (p_jobs)
     and exists (
       select 1 from public.concept_review_progress_runs r
        where r.id = p.active_run_id and r.state <> 'running'
     );
end;
$fn$;

create or replace function public.concept_review_progress_touch(p_ids uuid[], p_graph boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_src uuid[];
  v_ids uuid[];
  v_jobs uuid[];
begin
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_src
    from unnest(coalesce(p_ids, '{}'::uuid[])) x
   where x is not null;
  if cardinality(v_src) = 0 or not exists (select 1 from public.concept_review_jobs) then
    return;
  end if;
  if p_graph then
    select coalesce(array_agg(distinct id), '{}'::uuid[]) into v_ids
      from (
        select unnest(v_src) as id
        union
        select r.related_id from public.concept_relations r where r.concept_id = any (v_src)
        union
        select r.concept_id from public.concept_relations r where r.related_id = any (v_src)
      ) s;
  else
    v_ids := v_src;
  end if;
  if not exists (select 1 from public.concept_review_walks w where w.concept_ids && v_ids)
     and not (p_graph and exists (
       select 1 from public.concept_review_progress_deps d
        where d.reason = 'compared' and d.concept_id = any (v_src)
     )) then
    return;
  end if;
  select coalesce(array_agg(distinct a.job_id), '{}'::uuid[]) into v_jobs
    from (
      select j.id as job_id
        from public.concept_review_jobs j
        join public.concept_review_walks w on w.id = j.walk_id and w.concept_ids && v_ids
        join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on u.cid = any (v_ids)
      union
      select d.job_id
        from public.concept_review_progress_deps d
       where p_graph and d.reason = 'compared' and d.concept_id = any (v_src)
    ) a;
  if cardinality(v_jobs) = 0 then
    return;
  end if;
  insert into public.concept_review_progress_jobs (job_id, input_version)
  select u.id, 0 from unnest(v_jobs) as u(id)
  on conflict (job_id) do nothing;
  perform 1 from public.concept_review_progress_jobs where job_id = any (v_jobs) for update;
  update public.concept_review_progress_positions p
     set dirty_token = p.dirty_token + 1
    from (
      select distinct j.id as job_id, u.pos::integer as pos
        from public.concept_review_jobs j
        join public.concept_review_walks w on w.id = j.walk_id and w.concept_ids && v_ids
        join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on u.cid = any (v_ids)
      union
      select d.job_id, d.pos
        from public.concept_review_progress_deps d
       where p_graph and d.reason = 'compared' and d.concept_id = any (v_src)
    ) a
   where p.job_id = a.job_id and p.pos = a.pos;
  perform public.concept_review_progress_bump(v_jobs);
end;
$fn$;

create or replace function public.concept_review_progress_touch_pos(p_job_id uuid, p_pos integer)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_job_id is null or p_pos is null then
    return;
  end if;
  insert into public.concept_review_progress_jobs (job_id, input_version)
  values (p_job_id, 0)
  on conflict (job_id) do nothing;
  perform 1 from public.concept_review_progress_jobs where job_id = p_job_id for update;
  update public.concept_review_progress_positions
     set dirty_token = dirty_token + 1
   where job_id = p_job_id and pos = p_pos;
  perform public.concept_review_progress_bump(array[p_job_id]);
end;
$fn$;

create or replace function public.concept_review_progress_refresh_deps(p_job_id uuid, p_pos integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_walk uuid;
begin
  select walk_id into v_walk from public.concept_review_jobs where id = p_job_id;
  if v_walk is null then
    return;
  end if;
  delete from public.concept_review_progress_deps d
   where d.job_id = p_job_id and (p_pos is null or d.pos = p_pos);
  insert into public.concept_review_progress_deps (job_id, pos, concept_id, reason)
  select distinct p_job_id, u.pos::integer, u.cid, 'self'
    from public.concept_review_walks w
    join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on p_pos is null or u.pos = p_pos
   where w.id = v_walk and u.cid is not null
  union
  select distinct p_job_id, u.pos::integer,
         case when r.concept_id = u.cid then r.related_id else r.concept_id end, 'relation'
    from public.concept_review_walks w
    join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on p_pos is null or u.pos = p_pos
    join public.concept_relations r on r.concept_id = u.cid or r.related_id = u.cid
   where w.id = v_walk
  union
  select distinct p_job_id, u.pos::integer, public.course_think_uuid(e ->> 'id'), 'compared'
    from public.concept_review_walks w
    join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on p_pos is null or u.pos = p_pos
    join lateral (
      select distinct on (r.scope) r.compared
        from public.concept_quality_reviews r
       where r.concept_id = u.cid
       order by r.scope, r.created_at desc, r.id desc
    ) rev on true
    cross join lateral jsonb_array_elements(coalesce(rev.compared, '[]'::jsonb)) e
   where w.id = v_walk and public.course_think_uuid(e ->> 'id') is not null
  on conflict do nothing;
end;
$fn$;

create or replace function public.concept_review_progress_action_concepts(p_payload jsonb)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(array_agg(distinct cid), '{}'::uuid[])
    from (
      select public.course_think_uuid(e ->> 'concept_id') as cid
        from jsonb_array_elements(
          case when jsonb_typeof(p_payload -> 'items') = 'array' then p_payload -> 'items' else '[]'::jsonb end
        ) e
      union
      select ap.concept_id
        from jsonb_array_elements(
          case when jsonb_typeof(p_payload -> 'items') = 'array' then p_payload -> 'items' else '[]'::jsonb end
        ) e
        join public.concept_appearances ap on ap.id = public.course_think_uuid(e ->> 'placement_id')
    ) s
   where cid is not null;
$fn$;

create or replace function public.concept_review_progress_trg_concept()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op = 'DELETE' then
    perform public.concept_review_progress_touch(array[old.id], true);
    return old;
  end if;
  if old.name is not distinct from new.name
     and old.content is not distinct from new.content
     and old.main_category_id is not distinct from new.main_category_id then
    return new;
  end if;
  perform public.concept_review_progress_touch(array[new.id], true);
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_statement()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.version, 0) > 0 then
      perform public.concept_review_progress_touch(array[new.concept_id], true);
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if coalesce(old.version, 0) > 0 then
      perform public.concept_review_progress_touch(array[old.concept_id], true);
    end if;
    return old;
  elsif (coalesce(old.version, 0) > 0 or coalesce(new.version, 0) > 0)
        and (old.version is distinct from new.version or old.concept_id is distinct from new.concept_id) then
    perform public.concept_review_progress_touch(array[old.concept_id, new.concept_id], true);
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_source()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op = 'DELETE' then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
    return old;
  end if;
  perform public.concept_review_progress_touch(array[new.concept_id], false);
  if tg_op = 'UPDATE' and old.concept_id is distinct from new.concept_id then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_appearance()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op = 'DELETE' then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
    return old;
  end if;
  perform public.concept_review_progress_touch(array[new.concept_id], false);
  if tg_op = 'UPDATE' and old.concept_id is distinct from new.concept_id then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_relation()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_ids uuid[] := '{}'::uuid[];
begin
  if tg_op in ('DELETE', 'UPDATE') then
    v_ids := v_ids || array[old.concept_id, old.related_id];
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_ids := v_ids || array[new.concept_id, new.related_id];
  end if;
  perform public.concept_review_progress_touch(v_ids, false);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  r record;
begin
  if tg_op = 'DELETE' then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
    return old;
  end if;
  perform public.concept_review_progress_touch(array[new.concept_id], false);
  for r in
    select j.id as job_id, u.pos::integer as pos
      from public.concept_review_jobs j
      join public.concept_review_walks w on w.id = j.walk_id
      join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on u.cid = new.concept_id
  loop
    perform public.concept_review_progress_refresh_deps(r.job_id, r.pos);
  end loop;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_type_link()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op in ('DELETE', 'UPDATE') then
    perform public.concept_review_progress_touch(array[old.concept_id], false);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.concept_review_progress_touch(array[new.concept_id], false);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_ids uuid[];
begin
  if tg_op <> 'UPDATE' or old.name is not distinct from new.name then
    return new;
  end if;
  select coalesce(array_agg(concept_id), '{}'::uuid[]) into v_ids
    from public.concept_type_links where type_id = new.id;
  perform public.concept_review_progress_touch(v_ids, false);
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_folder()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_root uuid;
  v_ids uuid[];
begin
  v_root := case when tg_op = 'DELETE' then old.id else new.id end;
  if tg_op = 'UPDATE' and old.name is not distinct from new.name and old.parent_id is not distinct from new.parent_id then
    return new;
  end if;
  with recursive down as (
    select v_root as id
    union all
    select c.id from public.concept_categories c join down d on c.parent_id = d.id
  )
  select coalesce(array_agg(c.id), '{}'::uuid[]) into v_ids
    from public.concepts c
   where c.main_category_id in (select id from down);
  perform public.concept_review_progress_touch(v_ids, false);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_unit_archive()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_ids uuid[];
begin
  if old.archived_at is not distinct from new.archived_at then
    return new;
  end if;
  select coalesce(array_agg(distinct a.concept_id), '{}'::uuid[]) into v_ids
    from public.concept_appearances a
   where a.course_unit_id = new.id;
  perform public.concept_review_progress_touch(v_ids, false);
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_course_archive()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_ids uuid[];
begin
  if old.archived_at is not distinct from new.archived_at then
    return new;
  end if;
  select coalesce(array_agg(distinct a.concept_id), '{}'::uuid[]) into v_ids
    from public.concept_appearances a
    join public.course_map_units u on u.id = a.course_unit_id
   where u.course_id = new.id;
  perform public.concept_review_progress_touch(v_ids, false);
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_action()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op in ('DELETE', 'UPDATE') then
    perform public.concept_review_progress_touch(public.concept_review_progress_action_concepts(old.payload), false);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.concept_review_progress_touch(public.concept_review_progress_action_concepts(new.payload), false);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if tg_op in ('DELETE', 'UPDATE') then
    perform public.concept_review_progress_touch_pos(old.job_id, old.pos);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.job_id is distinct from old.job_id or new.pos is distinct from old.pos) then
    perform public.concept_review_progress_touch_pos(new.job_id, new.pos);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_walk()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
declare
  v_jobs uuid[];
begin
  if tg_op = 'UPDATE' and old.concept_ids is not distinct from new.concept_ids then
    return new;
  end if;
  select coalesce(array_agg(id), '{}'::uuid[]) into v_jobs
    from public.concept_review_jobs
   where walk_id = case when tg_op = 'DELETE' then old.id else new.id end;
  update public.concept_review_progress_jobs
     set needs_rebuild = true
   where job_id = any (v_jobs);
  perform public.concept_review_progress_bump(v_jobs);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$trg$;

create or replace function public.concept_review_progress_trg_job_total()
returns trigger
language plpgsql
security definer
set search_path = public
as $trg$
begin
  if old.total is distinct from new.total then
    perform public.concept_review_progress_bump(array[new.id]);
  end if;
  return new;
end;
$trg$;

drop trigger if exists trg_concept_review_progress_concept on public.concepts;
create trigger trg_concept_review_progress_concept
  after update of name, content, main_category_id or delete on public.concepts
  for each row execute function public.concept_review_progress_trg_concept();

drop trigger if exists trg_concept_review_progress_statement on public.concept_statements;
create trigger trg_concept_review_progress_statement
  after insert or delete or update of version, concept_id on public.concept_statements
  for each row execute function public.concept_review_progress_trg_statement();

drop trigger if exists trg_concept_review_progress_source on public.concept_sources;
create trigger trg_concept_review_progress_source
  after insert or delete or update of book_id, grade_label, unit_path, raw_page, display_page, concept_id
  on public.concept_sources
  for each row execute function public.concept_review_progress_trg_source();

drop trigger if exists trg_concept_review_progress_appearance on public.concept_appearances;
create trigger trg_concept_review_progress_appearance
  after insert or delete or update of course_unit_id, concept_id on public.concept_appearances
  for each row execute function public.concept_review_progress_trg_appearance();

drop trigger if exists trg_concept_review_progress_relation on public.concept_relations;
create trigger trg_concept_review_progress_relation
  after insert or delete or update of concept_id, related_id, kind, note, context, basis
  on public.concept_relations
  for each row execute function public.concept_review_progress_trg_relation();

drop trigger if exists trg_concept_review_progress_review on public.concept_quality_reviews;
create trigger trg_concept_review_progress_review
  after insert or delete on public.concept_quality_reviews
  for each row execute function public.concept_review_progress_trg_review();

drop trigger if exists trg_concept_review_progress_type_link on public.concept_type_links;
create trigger trg_concept_review_progress_type_link
  after insert or delete or update of concept_id, type_id on public.concept_type_links
  for each row execute function public.concept_review_progress_trg_type_link();

drop trigger if exists trg_concept_review_progress_type on public.concept_types;
create trigger trg_concept_review_progress_type
  after update of name on public.concept_types
  for each row execute function public.concept_review_progress_trg_type();

drop trigger if exists trg_concept_review_progress_folder on public.concept_categories;
create trigger trg_concept_review_progress_folder
  after update of name, parent_id or delete on public.concept_categories
  for each row execute function public.concept_review_progress_trg_folder();

drop trigger if exists trg_concept_review_progress_unit_archive on public.course_map_units;
create trigger trg_concept_review_progress_unit_archive
  after update of archived_at on public.course_map_units
  for each row execute function public.concept_review_progress_trg_unit_archive();

drop trigger if exists trg_concept_review_progress_course_archive on public.course_maps;
create trigger trg_concept_review_progress_course_archive
  after update of archived_at on public.course_maps
  for each row execute function public.concept_review_progress_trg_course_archive();

drop trigger if exists trg_concept_review_progress_action on public.ai_actions;
create trigger trg_concept_review_progress_action
  after insert or delete or update of status, result, error, payload on public.ai_actions
  for each row execute function public.concept_review_progress_trg_action();

drop trigger if exists trg_concept_review_progress_item on public.concept_review_job_items;
create trigger trg_concept_review_progress_item
  after insert or delete or update on public.concept_review_job_items
  for each row execute function public.concept_review_progress_trg_item();

drop trigger if exists trg_concept_review_progress_walk on public.concept_review_walks;
create trigger trg_concept_review_progress_walk
  after insert or delete or update of concept_ids on public.concept_review_walks
  for each row execute function public.concept_review_progress_trg_walk();

drop trigger if exists trg_concept_review_progress_job_total on public.concept_review_jobs;
create trigger trg_concept_review_progress_job_total
  after update of total on public.concept_review_jobs
  for each row execute function public.concept_review_progress_trg_job_total();

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 위치 판정은 기존 함수를 그대로 부른다. 상태 조회는 부르지 않는다.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_progress_judge(
  p_job_id uuid, p_pos integer, p_pending uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_job public.concept_review_jobs;
  v_cid uuid;
  v_state text;
  v_next text;
  v_reason text;
  v_action uuid;
  v_action_items integer[];
  v_draft_version jsonb;
  v_held jsonb;
  v_card_id uuid;
  v_card_status text;
  v_card_error text;
  v_marks jsonb;
  v_cs jsonb;
  v_hold jsonb;
  v_cat text;
  v_met boolean := false;
  v_open jsonb;
begin
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    return null;
  end if;
  select u.cid into v_cid
    from public.concept_review_walks w
    join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on u.pos = p_pos
   where w.id = v_job.walk_id;
  if v_cid is null then
    return null;
  end if;
  select i.state, i.next_action, i.reason, i.action_id, i.action_items, to_jsonb(i.draft_version), i.held_fixes,
         a.id, a.status, a.error
    into v_state, v_next, v_reason, v_action, v_action_items, v_draft_version, v_held,
         v_card_id, v_card_status, v_card_error
    from (select 1) s
    left join public.concept_review_job_items i on i.job_id = p_job_id and i.pos = p_pos
    left join public.ai_actions a on a.id = i.action_id;
  if exists (select 1 from public.concepts where id = v_cid) then
    v_marks := public.concept_review_marks(v_cid);
  end if;
  v_cs := public.concept_review_job_concept_state(v_cid, coalesce(p_pending, '{}'::uuid[]), v_marks);
  v_hold := case when v_state = 'held' then public.concept_review_job_hold_view(v_held) else null end;
  v_cat := case
    when v_cs ->> 'state' = 'missing' then 'missing'
    when v_state = 'held' and jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0 then 'todo'
    when v_state = 'held' and coalesce((v_hold ->> 'waiting')::boolean, false) then 'awaiting'
    when v_state = 'held' then 'open'
    when v_state = 'submitted' and v_card_status = 'proposed' and coalesce(v_card_error, '') <> '' then 'open'
    when v_cs ->> 'state' = 'complete' then 'complete'
    when v_state = 'drafted' then 'drafted'
    when v_cs ->> 'state' = 'pending' then 'awaiting'
    when v_state in ('deferred', 'failed') then 'open'
    when v_state = 'submitted' and (v_card_id is null or v_card_status = 'rejected'
                                    or public.concept_review_job_item_skipped(v_action, v_action_items)) then 'open'
    when v_cs ->> 'state' = 'open' then 'open'
    when v_state is null then 'not_reviewed'
    else 'todo'
  end;
  if v_state = 'held' then
    v_next := coalesce(v_hold ->> 'next_action', case
      when jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0
        then '의존하던 변경이 반영됐습니다. 다음 검수가 그 범위만 다시 판단합니다.'
      else '의존하는 변경 결과를 확인한 뒤 그 범위만 다시 판단합니다.' end);
  elsif v_state = 'submitted' and v_card_status = 'proposed' and coalesce(v_card_error, '') <> '' then
    v_next := '지난 승인에서 반영하지 못했습니다. 카드는 그대로이니 다시 승인하거나 거절할 수 있습니다.';
  elsif v_cat = 'open' and v_state = 'submitted' and v_cs ->> 'state' <> 'open' then
    v_next := case
      when v_card_id is null then '카드가 없어졌다(대화 삭제 등). 다음 묶음 검수에서 다시 판단한다'
      when v_card_status = 'rejected' then '거절된 카드다. 사용자 의견을 확인하고 고친 초안을 저장한다(같은 내용 재제출 안 함)'
      else '승인 때 뺀 항목이 있다. 사용자 의견을 확인한 뒤 다시 검수한다'
    end;
  elsif v_cat = 'open' and v_state is distinct from 'deferred' and v_state is distinct from 'failed' then
    v_next := '사용자 확인이 필요한 기록: ' || coalesce((
      select string_agg((e ->> 'scope') || ' ' || coalesce(e ->> 'outcome', '') ||
                        case when e ->> 'state' = 'issue' then '(고치기 카드 거절·일부 반영)' else '' end, ', ')
        from jsonb_array_elements(v_cs -> 'open') e
    ), '');
  elsif v_cat in ('todo', 'not_reviewed') then
    v_next := '다음 묶음 검수에서 부족한 범위를 검수한다: ' || coalesce((
      select string_agg(x #>> '{}', ', ') from jsonb_array_elements(v_cs -> 'todo') x
    ), '');
  elsif v_cat = 'awaiting' then
    v_next := '승인 대기 카드(검토·고치기·배치)의 결과를 본다';
  end if;
  if v_cs -> 'conditions' ->> 'text' = 'met'
     and v_cs -> 'conditions' ->> 'foundation' = 'met'
     and v_cs -> 'conditions' ->> 'placement' = 'met'
     and v_marks is not null
     and public.concept_review_first_pass_met(v_cid, p_job_id, p_pos, v_cs, v_marks, v_hold) then
    v_met := true;
  end if;
  if v_cat in ('open', 'drafted', 'todo') then
    v_open := jsonb_build_object(
      'position', p_pos, 'concept_id', v_cid,
      'name', (select name from public.concepts where id = v_cid),
      'category', v_cat, 'item_state', v_state, 'next_action', v_next, 'reason', v_reason,
      'action_id', v_action, 'draft_version', v_draft_version,
      'conditions', v_cs -> 'conditions', 'todo', v_cs -> 'todo', 'open', v_cs -> 'open'
    );
  end if;
  return jsonb_build_object(
    'concept_id', v_cid,
    'category', v_cat,
    'cond_text', coalesce(v_cs -> 'conditions' ->> 'text' = 'met', false),
    'cond_foundation', coalesce(v_cs -> 'conditions' ->> 'foundation' = 'met', false),
    'cond_placement', coalesce(v_cs -> 'conditions' ->> 'placement' = 'met', false),
    'first_pass', v_met,
    'open_payload', v_open
  );
end;
$fn$;

create or replace function public.concept_review_progress_finish(p_job_id uuid, p_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_job public.concept_review_jobs;
  v_walk_n integer;
  v_complete integer;
  v_awaiting integer;
  v_drafted integer;
  v_open integer;
  v_todo integer;
  v_not integer;
  v_missing integer;
  v_text integer;
  v_found integer;
  v_place integer;
  v_met integer;
  v_pct numeric;
  v_line text;
  v_counts jsonb;
  v_cond jsonb;
  v_fp jsonb;
  v_mismatch boolean;
  v_snap jsonb;
begin
  select * into v_prog from public.concept_review_progress_jobs where job_id = p_job_id for update;
  select * into v_run from public.concept_review_progress_runs where id = p_run_id;
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if v_prog.input_version is distinct from v_run.input_version
     or v_prog.active_run_id is distinct from p_run_id
     or v_run.state <> 'running' then
    update public.concept_review_progress_runs
       set state = 'superseded', finished_at = now()
     where id = p_run_id and state = 'running';
    update public.concept_review_progress_jobs
       set active_run_id = null
     where job_id = p_job_id and active_run_id = p_run_id;
    delete from public.concept_review_progress_stage where run_id = p_run_id;
    return false;
  end if;
  select coalesce(cardinality(w.concept_ids), 0) into v_walk_n
    from public.concept_review_walks w where w.id = v_job.walk_id;

  if v_run.kind = 'rebuild' then
    if (select count(*) from public.concept_review_progress_stage where run_id = p_run_id) <> v_walk_n
       or exists (
         select 1 from generate_series(1, v_walk_n) s(pos)
          where not exists (
            select 1 from public.concept_review_progress_stage g
             where g.run_id = p_run_id and g.pos = s.pos
          )
       ) then
      return false;
    end if;
    delete from public.concept_review_progress_positions where job_id = p_job_id;
    insert into public.concept_review_progress_positions (
      job_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, open_payload,
      dirty_token, published_token
    )
    select p_job_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, open_payload, 0, 0
      from public.concept_review_progress_stage where run_id = p_run_id;
    perform public.concept_review_progress_refresh_deps(p_job_id, null);
  elsif exists (
    select 1 from public.concept_review_progress_positions
     where job_id = p_job_id and dirty_token > published_token
  ) or v_prog.needs_rebuild
     or (select count(*) from public.concept_review_progress_positions where job_id = p_job_id) <> v_walk_n then
    return false;
  end if;

  select
    count(*) filter (where category = 'complete'),
    count(*) filter (where category = 'awaiting'),
    count(*) filter (where category = 'drafted'),
    count(*) filter (where category = 'open'),
    count(*) filter (where category = 'todo'),
    count(*) filter (where category = 'not_reviewed'),
    count(*) filter (where category = 'missing'),
    count(*) filter (where cond_text),
    count(*) filter (where cond_foundation),
    count(*) filter (where cond_placement),
    count(*) filter (where first_pass)
    into v_complete, v_awaiting, v_drafted, v_open, v_todo, v_not, v_missing, v_text, v_found, v_place, v_met
    from public.concept_review_progress_positions
   where job_id = p_job_id;

  v_counts := jsonb_build_object(
    'complete', v_complete, 'awaiting', v_awaiting, 'drafted', v_drafted, 'open', v_open,
    'todo', v_todo, 'not_reviewed', v_not, 'missing', v_missing
  );
  v_cond := jsonb_build_object('text', v_text, 'foundation', v_found, 'placement', v_place);
  if v_job.total = 0 then
    v_pct := null;
    v_line := format('1차 검수 3조건 충족: %s / %s개', v_met, v_job.total);
  else
    v_pct := round((v_met::numeric * 100) / v_job.total, 1);
    v_line := format('1차 검수 3조건 충족: %s / %s개(%s%%)', v_met, v_job.total, to_char(v_pct, 'FM999990.0'));
  end if;
  v_fp := jsonb_build_object('met', v_met, 'total', v_job.total, 'percent', v_pct, 'line', v_line);
  v_mismatch := v_walk_n <> v_job.total or v_missing > 0;
  v_snap := jsonb_build_object(
    'at', now(), 'input_version', v_prog.input_version, 'counts', v_counts, 'conditions', v_cond,
    'first_pass', v_fp,
    'progress_line', format('%s개 중 %s개 통합 완료', v_job.total, v_complete),
    'condition_line', format('조건별 충족(승인 기준): 표기·의미 %s · 기초 개념 %s · 배치 %s', v_text, v_found, v_place),
    'first_pass_line', v_line, 'total_mismatch', v_mismatch
  );
  update public.concept_review_progress_jobs
     set published_input_version = input_version,
         needs_rebuild = false,
         active_run_id = null,
         counts = v_counts,
         conditions = v_cond,
         first_pass = v_fp,
         progress_line = v_snap ->> 'progress_line',
         condition_line = v_snap ->> 'condition_line',
         first_pass_line = v_line,
         total_mismatch = v_mismatch,
         last_success = v_snap,
         last_success_at = now(),
         progress_error = null,
         updated_at = now()
   where job_id = p_job_id;
  update public.concept_review_progress_runs
     set state = 'published', finished_at = now(), updated_at = now(), error = null
   where id = p_run_id;
  delete from public.concept_review_progress_stage where run_id = p_run_id;
  delete from public.concept_review_progress_queue where job_id = p_job_id;
  return true;
end;
$fn$;

create or replace function public.concept_review_progress_assert_runner()
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is not null then
    perform public.concept_review_assert_operator();
    return;
  end if;
  if session_user not in ('postgres', 'supabase_admin')
     and not coalesce((select rolsuper from pg_roles where rolname = session_user), false) then
    raise exception 'concept_review_forbidden';
  end if;
end;
$fn$;

create or replace function public.concept_review_progress_step(p_job_id uuid default null, p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_job uuid := p_job_id;
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 200);
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_walk uuid[];
  v_walk_n integer;
  v_pos_n integer;
  v_dirty boolean;
  v_pending uuid[];
  v_row jsonb;
  v_token bigint;
  v_pos integer;
  v_cid uuid;
  v_processed integer := 0;
  v_next integer;
  v_err text;
  v_attempts integer;
begin
  perform public.concept_review_progress_assert_runner();
  if v_job is null then
    select q.job_id into v_job
      from public.concept_review_progress_queue q
     where q.attempts < 5
       and (q.next_attempt_at is null or q.next_attempt_at <= now())
     order by q.enqueued_at
     limit 1;
    if v_job is null then
      return jsonb_build_object('outcome', 'idle', 'more', false, 'processed', 0);
    end if;
  end if;
  if not exists (select 1 from public.concept_review_jobs where id = v_job) then
    raise exception 'concept_review_job_not_found';
  end if;
  if not pg_try_advisory_xact_lock(hashtext('concept_review_progress'), hashtext(v_job::text)) then
    return jsonb_build_object('outcome', 'already_running', 'more', false, 'job_id', v_job, 'processed', 0);
  end if;

  begin
    select * into v_run from public.concept_review_progress_runs where false;
    insert into public.concept_review_progress_jobs (job_id, input_version)
    values (v_job, 0)
    on conflict (job_id) do nothing;
    select * into v_prog from public.concept_review_progress_jobs where job_id = v_job;
    select w.concept_ids, coalesce(cardinality(w.concept_ids), 0)
      into v_walk, v_walk_n
      from public.concept_review_jobs j
      join public.concept_review_walks w on w.id = j.walk_id
     where j.id = v_job;
    select count(*) into v_pos_n from public.concept_review_progress_positions where job_id = v_job;
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    );

    select * into v_run from public.concept_review_progress_runs where false;
    if v_prog.active_run_id is not null then
      select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
    end if;
    if v_run.id is not null and v_run.state = 'running'
       and (v_run.input_version is distinct from v_prog.input_version
            or (v_run.kind <> 'rebuild' and v_prog.needs_rebuild)) then
      update public.concept_review_progress_runs
         set state = 'superseded', finished_at = now()
       where id = v_run.id;
      delete from public.concept_review_progress_stage where run_id = v_run.id;
      update public.concept_review_progress_jobs set active_run_id = null where job_id = v_job;
      select * into v_run from public.concept_review_progress_runs where false;
    end if;
    if v_run.id is not null and v_run.state = 'failed' and v_run.attempts >= 5
       and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed'), 'freshness', 'failed'
      );
    end if;
    if v_run.id is not null and v_run.state = 'running' and v_run.attempts > 0
       and v_run.next_attempt_at > now() and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed')
      );
    end if;

    if v_run.id is null or v_run.state <> 'running' then
      if v_prog.needs_rebuild or v_pos_n <> v_walk_n then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'rebuild', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_dirty then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'partial', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_prog.published_input_version is distinct from v_prog.input_version then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'resummarize', v_prog.input_version, 'running', 1)
        returning * into v_run;
      else
        delete from public.concept_review_progress_queue where job_id = v_job;
        return jsonb_build_object('outcome', 'idle', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      update public.concept_review_progress_jobs set active_run_id = v_run.id, updated_at = now() where job_id = v_job;
    end if;

    if v_run.kind = 'resummarize' then
      if public.concept_review_progress_finish(v_job, v_run.id) then
        return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', 0);
    end if;

    v_pending := public.concept_review_pending_concepts();
    if v_run.kind = 'rebuild' then
      for v_pos, v_cid in
        select u.pos::integer, u.cid
          from unnest(v_walk) with ordinality as u(cid, pos)
         where u.pos >= v_run.cursor_pos
         order by u.pos
         limit v_limit
      loop
        v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
        insert into public.concept_review_progress_stage (
          run_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, open_payload
        ) values (
          v_run.id, v_pos, (v_row ->> 'concept_id')::uuid, v_row ->> 'category',
          coalesce((v_row ->> 'cond_text')::boolean, false),
          coalesce((v_row ->> 'cond_foundation')::boolean, false),
          coalesce((v_row ->> 'cond_placement')::boolean, false),
          coalesce((v_row ->> 'first_pass')::boolean, false),
          v_row -> 'open_payload'
        )
        on conflict (run_id, pos) do update
          set concept_id = excluded.concept_id, category = excluded.category,
              cond_text = excluded.cond_text, cond_foundation = excluded.cond_foundation,
              cond_placement = excluded.cond_placement, first_pass = excluded.first_pass,
              open_payload = excluded.open_payload;
        v_processed := v_processed + 1;
        v_next := v_pos + 1;
      end loop;
      if v_processed = 0 and v_run.cursor_pos <= v_walk_n then
        raise exception 'progress_cursor_stuck';
      end if;
      update public.concept_review_progress_runs
         set cursor_pos = coalesce(v_next, v_run.cursor_pos), updated_at = now(), attempts = 0, next_attempt_at = null, error = null
       where id = v_run.id;
      if coalesce(v_next, v_run.cursor_pos) > v_walk_n or v_walk_n = 0 then
        if public.concept_review_progress_finish(v_job, v_run.id) then
          return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
        end if;
        return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', v_processed);
      end if;
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'cursor', v_next, 'freshness', 'refreshing');
    end if;

    for v_pos, v_token in
      select p.pos, p.dirty_token
        from public.concept_review_progress_positions p
       where p.job_id = v_job and p.dirty_token > p.published_token
       order by p.pos
       limit v_limit
    loop
      v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
      update public.concept_review_progress_positions
         set concept_id = (v_row ->> 'concept_id')::uuid,
             category = v_row ->> 'category',
             cond_text = coalesce((v_row ->> 'cond_text')::boolean, false),
             cond_foundation = coalesce((v_row ->> 'cond_foundation')::boolean, false),
             cond_placement = coalesce((v_row ->> 'cond_placement')::boolean, false),
             first_pass = coalesce((v_row ->> 'first_pass')::boolean, false),
             open_payload = v_row -> 'open_payload',
             published_token = v_token
       where job_id = v_job and pos = v_pos and dirty_token = v_token;
      if found then
        perform public.concept_review_progress_refresh_deps(v_job, v_pos);
        v_processed := v_processed + 1;
      end if;
    end loop;
    update public.concept_review_progress_runs
       set updated_at = now(), attempts = 0, next_attempt_at = null, error = null
     where id = v_run.id;
    if public.concept_review_progress_finish(v_job, v_run.id) then
      return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
    end if;
    if exists (
      select 1 from public.concept_review_progress_runs r
       where r.id = v_run.id and r.state = 'running'
    ) and exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    ) then
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'freshness', 'refreshing');
    end if;
    return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', v_processed);
  exception
    when others then
      if sqlerrm in ('concept_review_forbidden', 'concept_review_job_not_found') then
        raise;
      end if;
      v_err := case when sqlerrm ~ '^[a-z][a-z0-9_]{0,80}$' then sqlerrm else 'progress_step_failed' end;
      v_attempts := coalesce(v_run.attempts, 0) + 1;
      if v_run.id is not null then
        update public.concept_review_progress_runs
           set attempts = v_attempts,
               error = v_err,
               next_attempt_at = now() + make_interval(mins => v_attempts),
               state = case when v_attempts >= 5 then 'failed' else 'running' end,
               updated_at = now(),
               finished_at = case when v_attempts >= 5 then now() else null end
         where id = v_run.id;
        update public.concept_review_progress_jobs
           set progress_error = v_err, updated_at = now()
         where job_id = v_job;
        update public.concept_review_progress_queue
           set attempts = v_attempts, next_attempt_at = now() + make_interval(mins => v_attempts), last_error = v_err
         where job_id = v_job;
      end if;
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', v_processed,
        'error', v_err, 'sqlstate', sqlstate, 'attempts', v_attempts
      );
  end;
end;
$fn$;

create or replace function public.concept_review_progress_request(p_job_id uuid, p_rebuild boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_version bigint;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;
  insert into public.concept_review_progress_jobs (job_id, input_version, needs_rebuild)
  values (p_job_id, 1, coalesce(p_rebuild, true))
  on conflict (job_id) do update
    set needs_rebuild = public.concept_review_progress_jobs.needs_rebuild or excluded.needs_rebuild,
        updated_at = now();
  perform public.concept_review_progress_bump(array[p_job_id]);
  if coalesce(p_rebuild, true) then
    update public.concept_review_progress_jobs set needs_rebuild = true where job_id = p_job_id;
  end if;
  select input_version into v_version from public.concept_review_progress_jobs where job_id = p_job_id;
  return jsonb_build_object('enqueued', true, 'job_id', p_job_id, 'input_version', v_version, 'rebuild', coalesce(p_rebuild, true));
end;
$fn$;

create or replace procedure public.concept_review_progress_drive(
  p_job_id uuid default null,
  p_budget_ms integer default 15000,
  p_limit integer default 20
)
language plpgsql
security definer
set search_path = public
as $proc$
declare
  v_start timestamptz := clock_timestamp();
  v_budget integer := least(greatest(coalesce(p_budget_ms, 15000), 1000), 60000);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 200);
  v_out jsonb;
  v_n integer := 0;
begin
  loop
    exit when v_n >= 500;
    exit when clock_timestamp() > v_start + (v_budget * interval '1 millisecond');
    v_out := public.concept_review_progress_step(p_job_id, v_limit);
    commit;
    v_n := v_n + 1;
    exit when coalesce(v_out ->> 'more', 'false') <> 'true';
  end loop;
end;
$proc$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 상태 조회. 위치 판정과 지문을 다시 계산하지 않는다.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_limit integer := least(greatest(coalesce(p_open_limit, 20), 0), 60);
  v_dirty boolean := false;
  v_fresh text;
  v_open jsonb := '[]'::jsonb;
  v_cards jsonb;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  select * into v_prog from public.concept_review_progress_jobs where job_id = p_job_id;
  if v_prog.active_run_id is not null then
    select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
  end if;
  if v_prog.job_id is not null then
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = p_job_id and dirty_token > published_token
    );
  end if;
  v_fresh := case
    when v_prog.job_id is null then 'absent'
    when v_run.state = 'failed' and v_run.attempts >= 5 and v_run.input_version = v_prog.input_version then 'failed'
    when v_run.state = 'running' and v_run.input_version = v_prog.input_version then 'refreshing'
    when v_prog.published_input_version is not null
         and (v_prog.input_version is distinct from v_prog.published_input_version or v_dirty or v_prog.needs_rebuild) then 'stale'
    when v_prog.published_input_version is not null then 'current'
    else 'absent'
  end;
  if v_fresh = 'current' then
    select coalesce(jsonb_agg(s.open_payload order by s.pos), '[]'::jsonb) into v_open
      from (
        select pos, open_payload
          from public.concept_review_progress_positions
         where job_id = p_job_id and category in ('open', 'drafted', 'todo') and open_payload is not null
         order by pos
         limit v_limit
      ) s;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'action_id', a.id, 'kind', a.kind, 'conversation_id', a.conversation_id, 'conversation_title', c.title,
           'created_at', a.created_at, 'items', jsonb_array_length(coalesce(a.payload -> 'items', '[]'::jsonb)),
           'linked', jc.action_id is not null, 'legacy', coalesce(jc.legacy, false)
         ) order by a.created_at), '[]'::jsonb) into v_cards
    from public.ai_actions a
    left join public.ai_conversations c on c.id = a.conversation_id
    left join public.concept_review_job_cards jc on jc.job_id = v_job.id and jc.action_id = a.id
   where a.status = 'proposed'
     and (jc.action_id is not null or (a.kind = 'concept_review_record' and exists (
       select 1 from jsonb_array_elements(
         case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
       ) x where public.course_think_uuid(x ->> 'concept_id') = any (v_walk.concept_ids)
     )));
  return jsonb_build_object(
    'job', jsonb_build_object(
      'job_id', v_job.id, 'title', v_job.title, 'status', v_job.status, 'pause_reason', v_job.pause_reason,
      'walk_id', v_job.walk_id, 'walk_created_at', v_walk.created_at, 'total', v_job.total,
      'served_through', v_job.served_through, 'checkpoint', v_job.checkpoint,
      'created_by_me', v_job.created_by = auth.uid(), 'created_at', v_job.created_at, 'updated_at', v_job.updated_at,
      'lease_active', v_job.lease_until > now(), 'auto_run', v_job.auto_run, 'limits', v_job.limits
    ),
    'walk_total', coalesce(cardinality(v_walk.concept_ids), 0),
    'progress_freshness', v_fresh,
    'progress_error', case when v_fresh = 'failed' then v_prog.progress_error else null end,
    'progress_last_success', case when v_fresh = 'current' then null else v_prog.last_success end,
    'total_mismatch', case when v_fresh = 'current' then v_prog.total_mismatch else null end,
    'counts', case when v_fresh = 'current' then v_prog.counts else null end,
    'conditions', case when v_fresh = 'current' then v_prog.conditions else null end,
    'progress_line', case when v_fresh = 'current' then v_prog.progress_line else null end,
    'condition_line', case when v_fresh = 'current' then v_prog.condition_line else null end,
    'open_items', case when v_fresh = 'current' then v_open else '[]'::jsonb end,
    'pending_cards', coalesce(v_cards, '[]'::jsonb),
    'first_pass', case when v_fresh = 'current' then v_prog.first_pass else null end,
    'first_pass_line', case when v_fresh = 'current' then v_prog.first_pass_line else null end
  );
end;
$fn$;

create or replace function public.concept_review_job_status_live(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.concept_review_assert_operator();
  return public.concept_review_job_status_counts(p_job_id, p_open_limit);
end;
$fn$;

insert into public.concept_review_progress_deps (job_id, pos, concept_id, reason)
select distinct j.id, u.pos::integer, public.course_think_uuid(e ->> 'id'), 'compared'
  from public.concept_review_jobs j
  join public.concept_review_walks w on w.id = j.walk_id
  join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on true
  join lateral (
    select distinct on (r.scope) r.compared
      from public.concept_quality_reviews r
     where r.concept_id = u.cid
     order by r.scope, r.created_at desc, r.id desc
  ) rev on true
  cross join lateral jsonb_array_elements(coalesce(rev.compared, '[]'::jsonb)) e
 where public.course_think_uuid(e ->> 'id') is not null
on conflict do nothing;

revoke all on function public.concept_review_progress_bump(uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_touch(uuid[], boolean) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_touch_pos(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_refresh_deps(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_action_concepts(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_judge(uuid, integer, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_finish(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_assert_runner() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_concept() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_statement() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_source() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_appearance() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_relation() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_review() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_type_link() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_type() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_folder() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_unit_archive() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_course_archive() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_action() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_item() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_walk() from public, anon, authenticated, service_role;
revoke all on function public.concept_review_progress_trg_job_total() from public, anon, authenticated, service_role;

revoke all on function public.concept_review_progress_step(uuid, integer) from public, anon, service_role;
revoke all on function public.concept_review_progress_request(uuid, boolean) from public, anon, service_role;
revoke all on function public.concept_review_job_status_live(uuid, integer) from public, anon, service_role;
revoke all on procedure public.concept_review_progress_drive(uuid, integer, integer) from public, anon, service_role;
grant execute on function public.concept_review_progress_step(uuid, integer) to authenticated;
grant execute on function public.concept_review_progress_request(uuid, boolean) to authenticated;
grant execute on function public.concept_review_job_status_live(uuid, integer) to authenticated;
grant execute on procedure public.concept_review_progress_drive(uuid, integer, integer) to authenticated;

do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'concept-review-progress',
      '* * * * *',
      'call public.concept_review_progress_drive(null, 15000, 20)'
    );
  end if;
exception when others then
  raise notice 'concept_review_progress cron not scheduled: %', sqlerrm;
end
$cron$;

notify pgrst, 'reload schema';
