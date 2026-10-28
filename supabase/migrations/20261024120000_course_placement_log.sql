-- 20261024120000: 개념 배치 기록과 최근 변경 목록(운영자 결정 2026-10-24)
--
-- 설계: docs/architecture/course-map.md §6.3
--
-- 1) course_placement_log: 기준 단원 배치의 넣기·옮기기·빼기를 남긴다. concept_appearances 트리거가 쓰므로
--    운영자 직접(탐색도 RPC·개념 상세의 줄 빼기)과 Think 카드 승인 어느 길이든 남는다.
--    단원 안 순서 바꾸기·번호 다시 매기기·과정 저장 때 글 칸 맞추기는 남기지 않는다.
--    개념·단원을 가리키는 외래키를 두지 않는다. 기록은 개념 지우기를 막는 "붙은 것"이 아니고,
--    개념 이름·과정 이름·단원 경로는 그때 값으로 남긴다.
-- 2) course_think_action_apply: 승인하는 동안 카드 id를 거래 안에만 둔다. 기록의 action_id가 되고,
--    Think 카드로 뺀 배치를 운영자가 뺀 것과 구분한다. 나머지 동작은 20261023180000 정의 그대로다.
-- 3) course_recent_changes: 배치 기록 + 기존 본문 고친 기록(concept_content_revisions) + 서술 확정 기록
--    (concept_statement_revisions)을 시각 역순으로 읽는다. 아무것도 바꾸지 않는다.
--    기록을 시작하기 전에 놓인 배치는 놓은 시각과 지금 위치만 보인다(before_log). 지난 옮기기·빼기는 알 수 없다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 배치 기록
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.course_placement_log (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  at timestamptz not null default clock_timestamp(),
  action text not null check (action in ('add', 'move', 'remove')),
  placement_id uuid not null,
  concept_id uuid not null,
  concept_name text not null,
  course_id uuid,
  course_name text,
  -- 넣기·옮기기의 새 단원. 빼기는 비어 있다.
  unit_id uuid,
  unit_path text[] not null default '{}'::text[],
  -- 옮기기·빼기 전 단원. 넣기는 비어 있다.
  from_unit_id uuid,
  from_path text[] not null default '{}'::text[],
  origin text not null check (origin in ('owner', 'ai')),
  action_id uuid,
  note text,
  actor uuid default auth.uid()
);

create index if not exists course_placement_log_at_idx on public.course_placement_log (at desc, seq desc);
create index if not exists course_placement_log_placement_idx on public.course_placement_log (placement_id, action);

alter table public.course_placement_log enable row level security;
revoke all on table public.course_placement_log from public, anon, authenticated;

create or replace function public.course_placement_log_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action_id uuid := public.course_think_uuid(coalesce(current_setting('ygg.think_action_id', true), ''));
  v_row public.concept_appearances;
  v_action text;
  v_unit uuid;
  v_from uuid;
  v_origin text;
  v_note text;
  v_course public.course_maps;
begin
  if tg_op = 'DELETE' then
    if old.course_unit_id is null then
      return null;
    end if;
    v_row := old;
    v_action := 'remove';
    v_from := old.course_unit_id;
    v_origin := case when v_action_id is null then 'owner' else 'ai' end;
  elsif tg_op = 'INSERT' then
    if new.course_unit_id is null then
      return null;
    end if;
    v_row := new;
    v_action := 'add';
    v_unit := new.course_unit_id;
    v_origin := new.origin;
    v_note := new.note;
  else
    if new.course_unit_id is null or new.course_unit_id is not distinct from old.course_unit_id then
      return null;
    end if;
    v_row := new;
    v_action := case when old.course_unit_id is null then 'add' else 'move' end;
    v_unit := new.course_unit_id;
    v_from := old.course_unit_id;
    v_origin := new.origin;
    v_note := new.note;
  end if;

  select m.* into v_course
    from public.course_map_units u
    join public.course_maps m on m.id = u.course_id
   where u.id = coalesce(v_unit, v_from);

  insert into public.course_placement_log (
    action, placement_id, concept_id, concept_name, course_id, course_name,
    unit_id, unit_path, from_unit_id, from_path, origin, action_id, note
  ) values (
    v_action, v_row.id, v_row.concept_id,
    coalesce((select c.name from public.concepts c where c.id = v_row.concept_id), ''),
    v_course.id, v_course.name,
    v_unit, case when v_unit is null then '{}'::text[] else public.course_unit_path(v_unit) end,
    v_from, case when v_from is null then '{}'::text[] else public.course_unit_path(v_from) end,
    v_origin, v_action_id, v_note
  );
  return null;
end;
$$;

drop trigger if exists trg_concept_appearances_placement_log on public.concept_appearances;
create trigger trg_concept_appearances_placement_log
  after insert or update of course_unit_id or delete on public.concept_appearances
  for each row execute function public.course_placement_log_write();

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 카드 승인: 카드 id를 거래 안에 둔다(20261023180000 정의 + set_config)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_think_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_res jsonb;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  if jsonb_typeof(v_over) <> 'object' then
    raise exception 'course_think_bad_overrides';
  end if;
  perform set_config('ygg.think_action_id', p_id::text, true);
  if v_act.kind = 'course_map_change' then
    v_res := public.course_think_apply_map(v_act);
  elsif v_act.kind = 'course_map_create' then
    v_res := public.course_think_apply_create(v_act);
  elsif v_act.kind = 'concept_placement_change' then
    v_res := public.course_think_apply_placement(v_act, v_over);
  elsif v_act.kind = 'concept_library_change' then
    v_res := public.course_think_apply_library(v_act, v_over);
  elsif v_act.kind = 'concept_review_record' then
    v_res := public.course_think_apply_review(v_act, v_over);
  elsif v_act.kind = 'concept_relation_change' then
    v_res := public.course_think_apply_relation(v_act, v_over);
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;
  perform set_config('ygg.think_action_id', '', true);
  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 최근 변경 읽기
-- ─────────────────────────────────────────────────────────────────────────

-- p_kinds: placement(배치) · content(개념 본문·이름) · statement(서술 확정). 비우면 모두.
-- 다음 쪽은 앞 쪽 마지막 항목의 at·key를 p_before_at·p_before_key로 넘긴다.
create or replace function public.course_recent_changes(
  p_kinds text[] default null,
  p_before_at timestamptz default null,
  p_before_key text default null,
  p_limit integer default 60
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kinds text[] := coalesce(p_kinds, array['placement', 'content', 'statement']);
  v_limit integer := least(greatest(coalesce(p_limit, 60), 1), 200);
  v_items jsonb;
  v_more boolean;
begin
  perform public.course_map_assert_operator();
  if cardinality(v_kinds) = 0
     or exists (select 1 from unnest(v_kinds) k where k is null or k not in ('placement', 'content', 'statement')) then
    raise exception 'course_changes_bad_kinds';
  end if;

  with ev as (
    select l.at, 'p:' || lpad(l.seq::text, 19, '0') as key,
           jsonb_build_object(
             'kind', 'placement', 'action', l.action, 'before_log', false,
             'placement_id', l.placement_id, 'concept_id', l.concept_id,
             'concept_name', coalesce(c.name, l.concept_name), 'course_name', l.course_name,
             'path', to_jsonb(l.unit_path), 'from_path', to_jsonb(l.from_path),
             'origin', l.origin, 'action_id', l.action_id, 'note', l.note
           ) as item
      from public.course_placement_log l
      left join public.concepts c on c.id = l.concept_id
     where 'placement' = any (v_kinds)
    union all
    select a.created_at, 'b:' || a.id::text,
           jsonb_build_object(
             'kind', 'placement', 'action', 'add', 'before_log', true,
             'placement_id', a.id, 'concept_id', a.concept_id, 'concept_name', c.name, 'course_name', m.name,
             'path', to_jsonb(public.course_unit_path(a.course_unit_id)), 'from_path', '[]'::jsonb,
             'origin', a.origin, 'action_id', null, 'note', a.note
           )
      from public.concept_appearances a
      join public.course_map_units u on u.id = a.course_unit_id
      join public.course_maps m on m.id = u.course_id
      join public.concepts c on c.id = a.concept_id
     where 'placement' = any (v_kinds)
       and not exists (
         select 1 from public.course_placement_log l where l.placement_id = a.id and l.action = 'add'
       )
    union all
    select r.changed_at, 'c:' || r.id::text,
           jsonb_build_object(
             'kind', 'content', 'concept_id', r.concept_id, 'concept_name', coalesce(c.name, r.name),
             'before_name', r.name, 'after_name', coalesce(r.next_name, c.name),
             'renamed', r.name is distinct from coalesce(r.next_name, c.name),
             'content_changed', r.content is distinct from coalesce(r.next_content, c.content),
             'via', r.via, 'origin', r.draft_origin, 'note', r.note
           )
      from (
        select x.*,
               lead(x.name) over w as next_name,
               lead(x.content) over w as next_content
          from public.concept_content_revisions x
        window w as (partition by x.concept_id order by x.changed_at, x.id)
      ) r
      left join public.concepts c on c.id = r.concept_id
     where 'content' = any (v_kinds)
    union all
    select r.confirmed_at, 's:' || r.id::text,
           jsonb_build_object(
             'kind', 'statement', 'concept_id', s.concept_id, 'concept_name', c.name,
             'statement_id', s.id, 'role', s.role, 'title', r.content ->> 'title',
             'version', r.version, 'note', r.note
           )
      from public.concept_statement_revisions r
      join public.concept_statements s on s.id = r.statement_id
      join public.concepts c on c.id = s.concept_id
     where 'statement' = any (v_kinds)
  ), page as (
    select ev.at, ev.key, ev.item, row_number() over (order by ev.at desc, ev.key desc) as n
      from ev
     where p_before_at is null or (ev.at, ev.key) < (p_before_at, coalesce(p_before_key, ''))
     order by ev.at desc, ev.key desc
     limit v_limit + 1
  )
  select coalesce(
           jsonb_agg(p.item || jsonb_build_object('at', p.at, 'key', p.key) order by p.n) filter (where p.n <= v_limit),
           '[]'::jsonb
         ),
         count(*) > v_limit
    into v_items, v_more
    from page p;

  return jsonb_build_object('items', v_items, 'more', v_more);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.course_placement_log_write() from public, anon, authenticated;

revoke all on function public.course_think_action_apply(uuid, jsonb) from public, anon;
revoke all on function public.course_recent_changes(text[], timestamptz, text, integer) from public, anon;

grant execute on function public.course_think_action_apply(uuid, jsonb) to authenticated;
grant execute on function public.course_recent_changes(text[], timestamptz, text, integer) to authenticated;

notify pgrst, 'reload schema';
