-- 20261023120000: 개념 배치와 Think 승인 카드(과정 탐색도·배치·개념) (운영자 결정 2026-10-23)
--
-- 설계: docs/architecture/course-map.md(배치) · docs/architecture/ai-think-actions.md(카드)
--
-- 1) 배치
--   교육과정 등장 위치(concept_appearances)에 기준 단원(course_unit_id)과 단원 안 순서(unit_sort_order)를 더한다.
--   기준 단원이 있는 줄의 교육과정 판·학교급·과정 이름·단원 경로는 탐색도에서 채우고, 과정의 판이 오를 때마다 다시 맞춘다.
--   같은 개념은 한 단원에 한 번만 놓이고, 다른 단원·다른 과정에는 여러 번 놓일 수 있다.
--   기준 단원이 있는 줄은 아래 RPC로만 넣고 옮긴다. 빼기는 지금처럼 등장 위치 빼기(줄 삭제)로도 된다.
--   origin: owner(운영자가 직접) · ai(운영자가 승인한 Think 카드). Think 카드로 놓은 줄의 note 는 카드의 근거다.
--   보관한 단원에 놓인 개념은 지우지 않는다(단원을 되살리면 다시 보인다). 글로 적은 등장 위치는 지금 그대로다.
--
-- 2) Think 카드(ai_actions). Think는 제안만 남기고(course_think_action_propose), 바뀌는 것은 운영자 승인(course_think_action_apply)뿐이다.
--   course_map_change         과정 하나의 단원 더하기·이름 바꾸기·옮기기·보관과 과정 정보, 또는 과정 보관·되살리기. 통째로 되거나 안 된다.
--   course_map_create         새 과정과 단원.
--   concept_placement_change  과정 하나 안에서 개념 놓기·옮기기·빼기·순서(카드 하나에 50개까지).
--   concept_library_change    개념 만들기·고치기(이름·본문·유형·폴더)·서술 고치기·지우기(붙은 것이 하나도 없을 때만). 20개까지.
--   배치·개념 카드는 항목마다 따로 반영한다(하나가 실패해도 나머지는 반영하고, 결과에 항목별로 남는다).
--   운영자는 항목을 빼거나(skip) 배치 단원을 바꿔(units) 승인할 수 있다.
--   본문·서술은 승인하면 바로 확정된다. 고치기 전 값은 기존 기록 표에 "Think 카드 승인: 이유"로 남는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 배치 열
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_appearances
  add column if not exists course_unit_id uuid references public.course_map_units(id) on delete restrict,
  add column if not exists unit_sort_order integer,
  add column if not exists origin text not null default 'owner';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'concept_appearances_origin_chk') then
    alter table public.concept_appearances
      add constraint concept_appearances_origin_chk check (origin in ('owner', 'ai'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'concept_appearances_unit_chk') then
    alter table public.concept_appearances
      add constraint concept_appearances_unit_chk check (
        (course_unit_id is null and unit_sort_order is null)
        or (course_unit_id is not null and unit_sort_order is not null and unit_sort_order >= 0)
      );
  end if;
end $$;

-- 글로 적은 등장 위치는 지금처럼 겹치지 않게 보고, 기준 단원 줄은 단원·개념으로 본다.
drop index if exists public.concept_appearances_unique;
create unique index if not exists concept_appearances_unique on public.concept_appearances (
  concept_id, coalesce(statement_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(curriculum_code, ''), school_level, course_label, unit_path
) where course_unit_id is null;
create unique index if not exists concept_appearances_unit_concept
  on public.concept_appearances (course_unit_id, concept_id) where course_unit_id is not null;
create index if not exists concept_appearances_unit_order
  on public.concept_appearances (course_unit_id, unit_sort_order) where course_unit_id is not null;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 탐색도에서 글 칸 채우기
-- ─────────────────────────────────────────────────────────────────────────

-- 단원 이름을 위에서부터(대단원 → 그 단원). 보관한 단원도 이름은 있다.
create or replace function public.course_unit_path(p_unit_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  with recursive up as (
    select u.id, u.parent_id, u.name, 1 as n from public.course_map_units u where u.id = p_unit_id
    union all
    select p.id, p.parent_id, p.name, up.n + 1 from public.course_map_units p join up on p.id = up.parent_id where up.n < 5
  )
  select coalesce(array_agg(up.name order by up.n desc), '{}'::text[]) from up;
$$;

-- 기준 단원 줄은 RPC가 ygg.course_placement 를 켠 동안에만 넣고 바꾼다. 글 칸은 언제나 탐색도에서 다시 채운다.
create or replace function public.concept_appearance_unit_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
begin
  if new.course_unit_id is null then
    if tg_op = 'UPDATE' and old.course_unit_id is not null then
      raise exception 'course_placement_use_rpc';
    end if;
    new.unit_sort_order := null;
    return new;
  end if;
  if coalesce(current_setting('ygg.course_placement', true), '') <> 'on' then
    raise exception 'course_placement_use_rpc';
  end if;
  select m.* into v_course
    from public.course_map_units u
    join public.course_maps m on m.id = u.course_id
   where u.id = new.course_unit_id;
  new.curriculum_code := v_course.curriculum_code;
  new.school_level := v_course.school_level;
  new.course_label := v_course.name;
  new.unit_path := public.course_unit_path(new.course_unit_id);
  return new;
end;
$$;

drop trigger if exists trg_concept_appearances_unit_fill on public.concept_appearances;
create trigger trg_concept_appearances_unit_fill
  before insert or update of course_unit_id on public.concept_appearances
  for each row execute function public.concept_appearance_unit_fill();

-- 과정을 바꾸는 RPC는 모두 마지막에 판(version)을 올린다. 그때 그 과정에 놓인 줄의 글 칸을 다시 맞춘다.
create or replace function public.course_map_sync_appearances()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('ygg.course_placement', 'on', true);
  update public.concept_appearances a
     set course_unit_id = a.course_unit_id
    from public.course_map_units u
   where u.id = a.course_unit_id and u.course_id = new.id;
  perform set_config('ygg.course_placement', '', true);
  return null;
end;
$$;

drop trigger if exists trg_course_maps_sync_appearances on public.course_maps;
create trigger trg_course_maps_sync_appearances
  after update of version on public.course_maps
  for each row when (old.version is distinct from new.version)
  execute function public.course_map_sync_appearances();

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 읽기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_think_uuid(p text)
returns uuid
language sql
immutable
as $$
  select case when btrim(p) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then btrim(p)::uuid end;
$$;

create or replace function public.concept_folder_path(p_category_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  with recursive up as (
    select c.id, c.parent_id, c.name, 1 as n from public.concept_categories c where c.id = p_category_id
    union all
    select p.id, p.parent_id, p.name, up.n + 1 from public.concept_categories p join up on p.id = up.parent_id where up.n < 20
  )
  select coalesce(array_agg(up.name order by up.n desc), '{}'::text[]) from up;
$$;

-- 출처 학년 칸이 이 과정 키(교재 과정 목록)로 읽히는 출처가 있는지. 과정 키가 없는 과정은 언제나 아니다.
create or replace function public.concept_has_course_source(p_concept_id uuid, p_course_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_course_key is not null and exists (
    select 1 from public.concept_sources s
     where s.concept_id = p_concept_id
       and public._textbook_course_info(s.grade_label) ->> 'course_key' = p_course_key
  );
$$;

-- 살아 있는 과정·단원에 놓인 자리("과정 › 대 › 중 › 소").
create or replace function public.concept_placement_paths(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'course_id', m.id, 'unit_id', a.course_unit_id,
           'path', m.name || ' › ' || array_to_string(public.course_unit_path(a.course_unit_id), ' › ')
         ) order by m.sort_order, a.unit_path), '[]'::jsonb)
    from public.concept_appearances a
    join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
    join public.course_maps m on m.id = u.course_id and m.archived_at is null
   where a.concept_id = p_concept_id;
$$;

create or replace function public.course_placement_json(a public.concept_appearances)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', a.id, 'unit_id', a.course_unit_id, 'concept_id', a.concept_id, 'statement_id', a.statement_id,
    'sort', a.unit_sort_order, 'origin', a.origin, 'note', a.note, 'created_at', a.created_at,
    'name', c.name, 'sub_type', c.sub_type, 'type', t.name,
    'sources', (select count(*) from public.concept_sources s where s.concept_id = a.concept_id)
  )
    from public.concepts c
    left join public.concept_type_links l on l.concept_id = c.id
    left join public.concept_types t on t.id = l.type_id
   where c.id = a.concept_id;
$$;

-- 과정 하나의 살아 있는 단원에 놓인 개념(단원 → 단원 안 순서).
create or replace function public.course_map_placements(p_course_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.course_map_assert_operator();
  if not exists (select 1 from public.course_maps where id = p_course_id) then
    raise exception 'course_map_not_found';
  end if;
  return coalesce((
    select jsonb_agg(public.course_placement_json(a) order by a.course_unit_id, a.unit_sort_order, a.created_at, a.id)
      from public.concept_appearances a
      join public.course_map_units u on u.id = a.course_unit_id
     where u.course_id = p_course_id and u.archived_at is null
  ), '[]'::jsonb);
end;
$$;

-- 전체 개념 수, 살아 있는 과정·단원에 한 번이라도 놓인 개념 수, 과정별 놓인 줄 수.
create or replace function public.concept_placement_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.course_map_assert_operator();
  return jsonb_build_object(
    'concepts', (select count(*) from public.concepts),
    'placed', (
      select count(distinct a.concept_id)
        from public.concept_appearances a
        join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
        join public.course_maps m on m.id = u.course_id and m.archived_at is null
    ),
    'courses', coalesce((
      select jsonb_object_agg(x.course_id, x.n)
        from (
          select u.course_id, count(*) as n
            from public.concept_appearances a
            join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
           group by u.course_id
        ) x
    ), '{}'::jsonb)
  );
end;
$$;

-- Think가 고를 때 보는 개념 한 줄: 유형·폴더·본문 앞부분·출처(앞 4개, 책·학년·과정 키·책 단원·쪽)·지금 놓인 자리.
create or replace function public.concept_think_brief(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', c.id, 'name', c.name, 'type', t.name,
    'folder', to_jsonb(public.concept_folder_path(c.main_category_id)),
    'excerpt', left(regexp_replace(c.content, '\s+', ' ', 'g'), 160),
    'source_count', (select count(*) from public.concept_sources s where s.concept_id = c.id),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
               'book', f.name, 'grade', s.grade_label,
               'course_key', nullif(public._textbook_course_info(s.grade_label) ->> 'course_key', ''),
               'unit_path', to_jsonb(s.unit_path), 'page', coalesce(s.display_page, s.raw_page)
             ) order by s.created_at, s.id)
        from (
          select * from public.concept_sources s0 where s0.concept_id = c.id order by s0.created_at, s0.id limit 4
        ) s
        left join public.resource_files f on f.id = s.book_id
    ), '[]'::jsonb),
    'placements', public.concept_placement_paths(c.id)
  )
    from public.concepts c
    left join public.concept_type_links l on l.concept_id = c.id
    left join public.concept_types t on t.id = l.type_id
   where c.id = p_concept_id;
$$;

-- 후보 모음. course_sources: 출처가 이 과정 키로 읽히는데 이 과정에 아직 안 놓인 개념.
-- unplaced: 어디에도 안 놓인 개념. no_source: 출처도 없고 어디에도 안 놓인 개념. search: 이름에 p_q 가 들어간 개념.
create or replace function public.concept_placement_pool(p_course public.course_maps, p_mode text, p_q text)
returns setof public.concepts
language sql
stable
security definer
set search_path = public
as $$
  select c.*
    from public.concepts c
   where (p_q is null or strpos(lower(c.name), lower(p_q)) > 0)
     and case p_mode
       when 'course_sources' then
         public.concept_has_course_source(c.id, p_course.course_key)
         and not exists (
           select 1 from public.concept_appearances a
             join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
            where a.concept_id = c.id and u.course_id = p_course.id
         )
       when 'unplaced' then
         not exists (
           select 1 from public.concept_appearances a
             join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
             join public.course_maps m on m.id = u.course_id and m.archived_at is null
            where a.concept_id = c.id
         )
       when 'no_source' then
         not exists (select 1 from public.concept_sources s where s.concept_id = c.id)
         and not exists (
           select 1 from public.concept_appearances a
             join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
             join public.course_maps m on m.id = u.course_id and m.archived_at is null
            where a.concept_id = c.id
         )
       else true
     end;
$$;

create or replace function public.concept_placement_candidates(
  p_course_id uuid,
  p_mode text,
  p_query text default null,
  p_offset integer default 0,
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total integer;
  v_items jsonb;
begin
  perform public.course_map_assert_operator();
  select * into v_course from public.course_maps where id = p_course_id;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if p_mode is null or p_mode not in ('course_sources', 'unplaced', 'no_source', 'search') then
    raise exception 'course_placement_bad_mode';
  end if;
  if (p_mode = 'search' and v_q is null) or char_length(coalesce(v_q, '')) > 80 then
    raise exception 'course_placement_bad_query';
  end if;
  select count(*) into v_total from public.concept_placement_pool(v_course, p_mode, v_q);
  select coalesce(jsonb_agg(public.concept_think_brief(p.id) order by p.ord), '[]'::jsonb)
    into v_items
    from (
      select c.id,
             row_number() over (order by public.concept_folder_path(c.main_category_id), c.sort_order, c.name, c.id) as ord
        from public.concept_placement_pool(v_course, p_mode, v_q) c
       order by ord
      offset v_offset limit v_limit
    ) p;
  return jsonb_build_object(
    'course_id', v_course.id, 'course_name', v_course.name, 'course_key', v_course.course_key,
    'mode', p_mode, 'query', v_q, 'total', v_total, 'offset', v_offset, 'items', v_items
  );
end;
$$;

-- 지우기 전에 보는 "붙은 것". total 이 0일 때만 지울 수 있다. 유형 표시·고친 기록은 개념 자신의 것이라 세지 않는다.
create or replace function public.concept_attachments(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_n integer;
begin
  v := jsonb_build_object(
    'sources', (select count(*) from public.concept_sources where concept_id = p_concept_id),
    'statements', (select count(*) from public.concept_statements where concept_id = p_concept_id),
    'appearances', (
      select count(*) from public.concept_appearances where concept_id = p_concept_id and course_unit_id is null
    ),
    'placements', (
      select count(*) from public.concept_appearances where concept_id = p_concept_id and course_unit_id is not null
    ),
    'relations', (
      select count(*) from public.concept_relations where concept_id = p_concept_id or related_id = p_concept_id
    ),
    'reviews', (select count(*) from public.concept_reviews where concept_id = p_concept_id or other_id = p_concept_id),
    'criteria', (select count(*) from public.concept_criterion_links where concept_id = p_concept_id),
    'anchors', (
      select count(*) from public.concept_anchor_links where concept_id = p_concept_id or anchor_id = p_concept_id
    ),
    'content_draft', (select count(*) from public.concept_content_drafts where concept_id = p_concept_id)
  );
  if to_regclass('public.concept_shortcuts') is not null then
    execute 'select count(*) from public.concept_shortcuts where concept_id = $1' into v_n using p_concept_id;
    v := v || jsonb_build_object('shortcuts', v_n);
  end if;
  if to_regclass('public.operation_prompts') is not null then
    execute 'select count(*) from public.operation_prompts where concept_id = $1' into v_n using p_concept_id;
    v := v || jsonb_build_object('operation_prompts', v_n);
  end if;
  return v || jsonb_build_object('total', (select coalesce(sum(value::integer), 0) from jsonb_each_text(v)));
end;
$$;

-- Think가 고치기 전에 읽는 개념 전체: 본문·서술·붙은 것·출처·놓인 자리.
create or replace function public.concept_think_detail(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_concept public.concepts;
begin
  perform public.course_map_assert_operator();
  select * into v_concept from public.concepts where id = p_concept_id;
  if not found then
    raise exception 'concept_think_concept_not_found';
  end if;
  return public.concept_think_brief(p_concept_id) || jsonb_build_object(
    'content', v_concept.content,
    'content_draft_pending', exists (select 1 from public.concept_content_drafts d where d.concept_id = p_concept_id),
    'statements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'role', s.role, 'version', s.version, 'has_draft', s.draft is not null,
               'content', s.content
             ) order by (s.role <> 'core'), s.sort_order, s.created_at)
        from public.concept_statements s where s.concept_id = p_concept_id
    ), '[]'::jsonb),
    'attached', public.concept_attachments(p_concept_id)
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 배치 바꾸기(운영자 직접, Think 승인 공용)
-- ─────────────────────────────────────────────────────────────────────────

-- 살아 있는 과정의 살아 있는 단원.
create or replace function public.course_placement_unit(p_unit_id uuid)
returns public.course_map_units
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
begin
  select * into v_unit from public.course_map_units where id = p_unit_id;
  if not found or v_unit.archived_at is not null then
    raise exception 'course_placement_unit_not_found';
  end if;
  if exists (select 1 from public.course_maps where id = v_unit.course_id and archived_at is not null) then
    raise exception 'course_map_archived';
  end if;
  return v_unit;
end;
$$;

create or replace function public.course_placement_unit_in(p_unit_id uuid, p_course_id uuid)
returns public.course_map_units
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
begin
  v_unit := public.course_placement_unit(p_unit_id);
  if v_unit.course_id <> p_course_id then
    raise exception 'course_placement_unit_foreign';
  end if;
  return v_unit;
end;
$$;

-- 이 과정의 살아 있는 단원에 놓인 줄.
create or replace function public.course_placement_row_in(p_id uuid, p_course_id uuid)
returns public.concept_appearances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
begin
  select a.* into v_row
    from public.concept_appearances a
    join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
   where a.id = p_id and (p_course_id is null or u.course_id = p_course_id)
     for update of a;
  if not found then
    raise exception 'course_placement_not_found';
  end if;
  return v_row;
end;
$$;

create or replace function public.course_placement_renumber(p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.concept_appearances a
     set unit_sort_order = s.n
    from (
      select id, (row_number() over (order by unit_sort_order, created_at, id) - 1)::integer as n
        from public.concept_appearances where course_unit_id = p_unit_id
    ) s
   where a.id = s.id and a.unit_sort_order is distinct from s.n;
end;
$$;

-- 단원 맨 끝에 놓는다. 그 단원에 이미 있으면 course_placement_exists.
create or replace function public.course_placement_insert(p_unit_id uuid, p_concept_id uuid, p_origin text, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.course_placement_unit(p_unit_id);
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    raise exception 'course_placement_concept_not_found';
  end if;
  if exists (select 1 from public.concept_appearances where course_unit_id = p_unit_id and concept_id = p_concept_id) then
    raise exception 'course_placement_exists';
  end if;
  perform set_config('ygg.course_placement', 'on', true);
  insert into public.concept_appearances
    (concept_id, school_level, course_label, course_unit_id, unit_sort_order, origin, note, created_by)
  values (
    p_concept_id, '중', '-', p_unit_id,
    coalesce((select max(unit_sort_order) + 1 from public.concept_appearances where course_unit_id = p_unit_id), 0),
    p_origin, nullif(left(btrim(coalesce(p_note, '')), 500), ''), auth.uid()
  )
  returning id into v_id;
  perform set_config('ygg.course_placement', '', true);
  return v_id;
end;
$$;

-- 다른 단원 맨 끝으로 옮긴다. 누가 옮겼는지(origin)와 근거(note)는 옮긴 쪽 것으로 바뀐다.
create or replace function public.course_placement_move_row(p_id uuid, p_unit_id uuid, p_origin text, p_note text)
returns public.concept_appearances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
begin
  v_row := public.course_placement_row_in(p_id, null);
  perform public.course_placement_unit(p_unit_id);
  if v_row.course_unit_id = p_unit_id then
    raise exception 'course_placement_same_unit';
  end if;
  if exists (
    select 1 from public.concept_appearances where course_unit_id = p_unit_id and concept_id = v_row.concept_id
  ) then
    raise exception 'course_placement_exists';
  end if;
  perform set_config('ygg.course_placement', 'on', true);
  update public.concept_appearances
     set course_unit_id = p_unit_id,
         unit_sort_order = coalesce((
           select max(unit_sort_order) + 1 from public.concept_appearances where course_unit_id = p_unit_id
         ), 0),
         origin = p_origin,
         note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
   where id = p_id;
  perform set_config('ygg.course_placement', '', true);
  perform public.course_placement_renumber(v_row.course_unit_id);
  return v_row;
end;
$$;

-- p_ids 는 지금 그 단원에 놓인 줄 전부여야 한다(빠지거나 더 있으면 course_placement_stale).
create or replace function public.course_placement_reorder_rows(p_unit_id uuid, p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform 1 from public.concept_appearances where course_unit_id = p_unit_id for update;
  if p_ids is null
     or cardinality(p_ids) <> (select count(*) from public.concept_appearances where course_unit_id = p_unit_id)
     or cardinality(p_ids) <> (select count(distinct x) from unnest(p_ids) x where x is not null)
     or exists (
       select 1 from unnest(p_ids) x
        where not exists (select 1 from public.concept_appearances a where a.id = x and a.course_unit_id = p_unit_id)
     ) then
    raise exception 'course_placement_stale';
  end if;
  update public.concept_appearances a
     set unit_sort_order = (t.n - 1)::integer
    from unnest(p_ids) with ordinality as t(id, n)
   where a.id = t.id;
end;
$$;

create or replace function public.course_placement_add(p_unit_id uuid, p_concept_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
  v_id uuid;
begin
  perform public.course_map_assert_operator();
  v_unit := public.course_placement_unit(p_unit_id);
  if p_concept_ids is null or cardinality(p_concept_ids) = 0 or cardinality(p_concept_ids) > 100 then
    raise exception 'course_placement_bad_concepts';
  end if;
  perform 1 from public.course_map_units where id = p_unit_id for update;
  for v_id in
    select x from unnest(p_concept_ids) with ordinality as t(x, n) where x is not null group by x order by min(n)
  loop
    perform public.course_placement_insert(p_unit_id, v_id, 'owner', null);
  end loop;
  return public.course_map_placements(v_unit.course_id);
end;
$$;

create or replace function public.course_placement_remove(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
  v_course uuid;
begin
  perform public.course_map_assert_operator();
  v_row := public.course_placement_row_in(p_id, null);
  select course_id into v_course from public.course_map_units where id = v_row.course_unit_id;
  delete from public.concept_appearances where id = p_id;
  perform public.course_placement_renumber(v_row.course_unit_id);
  return public.course_map_placements(v_course);
end;
$$;

-- 운영자가 옮기면 Think 근거는 지운다(새 자리의 근거가 아니다).
create or replace function public.course_placement_move(p_id uuid, p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
  v_course uuid;
begin
  perform public.course_map_assert_operator();
  v_row := public.course_placement_move_row(p_id, p_unit_id, 'owner', null);
  select course_id into v_course from public.course_map_units where id = v_row.course_unit_id;
  return public.course_map_placements(v_course);
end;
$$;

create or replace function public.course_placement_reorder(p_unit_id uuid, p_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
begin
  perform public.course_map_assert_operator();
  v_unit := public.course_placement_unit(p_unit_id);
  perform public.course_placement_reorder_rows(p_unit_id, p_ids);
  return public.course_map_placements(v_unit.course_id);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) Think 카드 종류
-- ─────────────────────────────────────────────────────────────────────────

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
    'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change',
    'concept_draft_change', 'concept_criterion_change', 'concept_draft_rerun',
    'course_map_change', 'course_map_create', 'concept_placement_change', 'concept_library_change'
  ));

create or replace function public.course_think_level(p_depth integer)
returns text
language sql
immutable
as $$
  select (array['대단원', '중단원', '소단원'])[greatest(1, least(3, coalesce(p_depth, 1)))];
$$;

create or replace function public.course_think_curriculum(p_code text)
returns text
language sql
immutable
as $$
  select case p_code
    when 'legacy_1to6' then '옛날 교육과정(1~6차)'
    when 'k7_1997' then '7차 교육과정(1997)'
    when 'k7_2007' then '2007 개정(7차)'
    when 'rev_2009' then '2009 개정'
    when 'rev_2015' then '2015 개정'
    when 'rev_2022' then '2022 개정'
    else '교육과정 판 미기록'
  end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 단원 바꾸기 시험 실행(course_map_change)
-- ─────────────────────────────────────────────────────────────────────────
-- 아래 도우미는 course_think_ops_run 이 만든 임시 표 course_think_units(지금 단원 + 바꾼 내용)를 쓴다.
-- 오류 끝의 :n 은 몇 번째 바꾸기에서 막혔는지다.

create or replace function public.course_think_name(p text, p_n integer)
returns text
language plpgsql
immutable
as $$
declare
  v text := btrim(coalesce(p, ''));
begin
  if v = '' or char_length(v) > 80 then
    raise exception 'course_think_bad_name:%', p_n;
  end if;
  return v;
end;
$$;

-- 단원 id, 또는 같은 카드에서 앞서 더한 단원의 key. 비어 있거나 top 이면 null(대단원 자리).
create or replace function public.course_think_ref(p_ref text, p_keys jsonb, p_n integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v uuid;
  v_ref text := btrim(coalesce(p_ref, ''));
begin
  if v_ref = '' or lower(v_ref) = 'top' then
    return null;
  end if;
  if coalesce(p_keys, '{}'::jsonb) ? v_ref then
    v := public.course_think_uuid(p_keys ->> v_ref);
  else
    v := public.course_think_uuid(v_ref);
  end if;
  if v is null or not exists (select 1 from course_think_units where id = v) then
    raise exception 'course_think_unit_not_found:%', p_n;
  end if;
  return v;
end;
$$;

create or replace function public.course_think_path(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return (
    with recursive up as (
      select t.id, t.parent_id, t.name, 1 as n from course_think_units t where t.id = p_id
      union all
      select p.id, p.parent_id, p.name, up.n + 1 from course_think_units p join up on p.id = up.parent_id where up.n < 5
    )
    select string_agg(up.name, ' › ' order by up.n desc) from up
  );
end;
$$;

-- 단원의 깊이(대단원 1). null 이면 0.
create or replace function public.course_think_depth(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_id is null then
    return 0;
  end if;
  return (
    with recursive up as (
      select t.id, t.parent_id, 1 as n from course_think_units t where t.id = p_id
      union all
      select p.id, p.parent_id, up.n + 1 from course_think_units p join up on p.id = up.parent_id where up.n < 10
    )
    select max(n) from up
  );
end;
$$;

-- 단원과 그 아래 단원 id.
create or replace function public.course_think_subtree(p_id uuid)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
begin
  return array(
    with recursive d as (
      select t.id, 1 as h from course_think_units t where t.id = p_id
      union all
      select c.id, d.h + 1 from course_think_units c join d on c.parent_id = d.id where d.h < 10
    )
    select id from d
  );
end;
$$;

-- 단원을 p_parent 아래 자리로. first(맨 앞)·last(맨 끝)·after(p_after 바로 뒤). 비어 있으면 after 가 있을 때 after, 아니면 last.
create or replace function public.course_think_place(p_id uuid, p_parent uuid, p_position text, p_after uuid, p_n integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pos text := lower(btrim(coalesce(p_position, '')));
  v_new numeric;
  v_height integer;
begin
  if p_parent is not null and p_parent = any (public.course_think_subtree(p_id)) then
    raise exception 'course_think_cycle:%', p_n;
  end if;
  v_height := (
    with recursive d as (
      select t.id, 1 as h from course_think_units t where t.id = p_id
      union all
      select c.id, d.h + 1 from course_think_units c join d on c.parent_id = d.id where d.h < 10
    )
    select max(h) from d
  );
  if public.course_think_depth(p_parent) + v_height > 3 then
    raise exception 'course_think_too_deep:%', p_n;
  end if;
  if v_pos = '' then
    v_pos := case when p_after is null then 'last' else 'after' end;
  end if;
  update course_think_units t
     set pos = s.n * 2
    from (
      select id, row_number() over (order by pos, id) as n
        from course_think_units
       where parent_id is not distinct from p_parent and id <> p_id
    ) s
   where t.id = s.id;
  if v_pos = 'first' then
    v_new := 0;
  elsif v_pos = 'last' then
    v_new := coalesce((
      select max(pos) from course_think_units where parent_id is not distinct from p_parent and id <> p_id
    ), 0) + 2;
  elsif v_pos = 'after' then
    select pos + 1 into v_new
      from course_think_units
     where id = p_after and parent_id is not distinct from p_parent and id <> p_id;
    if v_new is null then
      raise exception 'course_think_bad_after:%', p_n;
    end if;
  else
    raise exception 'course_think_bad_position:%', p_n;
  end if;
  update course_think_units set parent_id = p_parent, pos = v_new where id = p_id;
end;
$$;

-- p_ops 를 지금 단원 위에 차례로 해 본다. 돌려줌: course_map_save 에 넘길 {units, archive, course}와 사람이 읽는 lines.
--   add     {key, parent, position, after, name}   key 는 제안 때 정한 새 단원 id(p_keys)와 짝이다. parent 가 비면 대단원.
--   rename  {unit, name}
--   move    {unit, parent, position, after}       parent 가 비면 지금 부모 그대로(순서만), top 이면 대단원 자리.
--   archive {unit}                                아래 단원도 함께 보관한다(지우지 않음).
--   course  {name, school_level, curriculum_code}  비어 있는 칸은 그대로. curriculum_code 가 '' 이면 비운다.
create or replace function public.course_think_ops_run(p_course public.course_maps, p_ops jsonb, p_keys jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op jsonb;
  v_kind text;
  v_key text;
  v_unit uuid;
  v_parent uuid;
  v_name text;
  v_old text;
  v_ids uuid[];
  v_n integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_course jsonb := '{}'::jsonb;
  v_parts text[];
  v_archive uuid[] := '{}'::uuid[];
  v_units jsonb;
begin
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 then
    raise exception 'course_think_bad_ops';
  end if;
  if jsonb_array_length(p_ops) > 60 then
    raise exception 'course_think_too_many';
  end if;

  drop table if exists pg_temp.course_think_units;
  create temp table course_think_units (
    id uuid primary key,
    parent_id uuid,
    name text not null,
    pos numeric not null,
    fresh boolean not null default false
  ) on commit drop;
  insert into course_think_units (id, parent_id, name, pos)
  select id, parent_id, name, sort_order
    from public.course_map_units
   where course_id = p_course.id and archived_at is null;

  for v_op in select e from jsonb_array_elements(p_ops) e loop
    v_n := v_n + 1;
    if jsonb_typeof(v_op) <> 'object' then
      raise exception 'course_think_bad_op:%', v_n;
    end if;
    v_kind := v_op ->> 'op';
    if v_kind = 'add' then
      v_key := btrim(coalesce(v_op ->> 'key', ''));
      v_unit := public.course_think_uuid(coalesce(p_keys, '{}'::jsonb) ->> v_key);
      if v_key = '' or v_unit is null or exists (select 1 from course_think_units where id = v_unit) then
        raise exception 'course_think_bad_key:%', v_n;
      end if;
      v_parent := public.course_think_ref(v_op ->> 'parent', p_keys, v_n);
      v_name := public.course_think_name(v_op ->> 'name', v_n);
      insert into course_think_units (id, parent_id, name, pos, fresh) values (v_unit, v_parent, v_name, 0, true);
      perform public.course_think_place(
        v_unit, v_parent, v_op ->> 'position', public.course_think_ref(v_op ->> 'after', p_keys, v_n), v_n
      );
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'op', 'add',
        'text', format('%s 더하기 · %s', public.course_think_level(public.course_think_depth(v_unit)),
                       public.course_think_path(v_unit))
      ));
    elsif v_kind = 'rename' then
      v_unit := public.course_think_ref(v_op ->> 'unit', p_keys, v_n);
      if v_unit is null then
        raise exception 'course_think_unit_not_found:%', v_n;
      end if;
      v_name := public.course_think_name(v_op ->> 'name', v_n);
      v_old := public.course_think_path(v_unit);
      update course_think_units set name = v_name where id = v_unit;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'op', 'rename', 'text', format('이름 바꾸기 · %s → %s', v_old, v_name)
      ));
    elsif v_kind = 'move' then
      v_unit := public.course_think_ref(v_op ->> 'unit', p_keys, v_n);
      if v_unit is null then
        raise exception 'course_think_unit_not_found:%', v_n;
      end if;
      if btrim(coalesce(v_op ->> 'parent', '')) = '' then
        v_parent := (select parent_id from course_think_units where id = v_unit);
      else
        v_parent := public.course_think_ref(v_op ->> 'parent', p_keys, v_n);
      end if;
      v_old := public.course_think_path(v_unit);
      perform public.course_think_place(
        v_unit, v_parent, v_op ->> 'position', public.course_think_ref(v_op ->> 'after', p_keys, v_n), v_n
      );
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'op', 'move',
        'text', format('옮기기 · %s → %s(%s)', v_old, public.course_think_path(v_unit),
                       public.course_think_level(public.course_think_depth(v_unit)))
      ));
    elsif v_kind = 'archive' then
      v_unit := public.course_think_ref(v_op ->> 'unit', p_keys, v_n);
      if v_unit is null then
        raise exception 'course_think_unit_not_found:%', v_n;
      end if;
      if (select fresh from course_think_units where id = v_unit) then
        raise exception 'course_think_bad_op:%', v_n;
      end if;
      v_old := public.course_think_path(v_unit);
      v_ids := public.course_think_subtree(v_unit);
      v_archive := v_archive || array(select id from course_think_units where id = any (v_ids) and not fresh);
      delete from course_think_units where id = any (v_ids);
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'op', 'archive',
        'text', format('보관 · %s%s', v_old,
                       case when cardinality(v_ids) > 1 then format(' (아래 단원 %s개 함께)', cardinality(v_ids) - 1) else '' end)
      ));
    elsif v_kind = 'course' then
      v_parts := '{}'::text[];
      if nullif(btrim(coalesce(v_op ->> 'name', '')), '') is not null then
        v_course := v_course || jsonb_build_object('name', btrim(v_op ->> 'name'));
        v_parts := v_parts || format('이름 %s → %s', p_course.name, btrim(v_op ->> 'name'));
      end if;
      if nullif(btrim(coalesce(v_op ->> 'school_level', '')), '') is not null then
        v_course := v_course || jsonb_build_object('school_level', btrim(v_op ->> 'school_level'));
        v_parts := v_parts || format('학교급 %s → %s', p_course.school_level, btrim(v_op ->> 'school_level'));
      end if;
      if v_op ->> 'curriculum_code' is not null then
        v_course := v_course || jsonb_build_object('curriculum_code', nullif(btrim(v_op ->> 'curriculum_code'), ''));
        v_parts := v_parts || format('교육과정 %s → %s', public.course_think_curriculum(p_course.curriculum_code),
                                     public.course_think_curriculum(nullif(btrim(v_op ->> 'curriculum_code'), '')));
      end if;
      if cardinality(v_parts) = 0 then
        raise exception 'course_think_bad_op:%', v_n;
      end if;
      perform public.course_map_check_course(
        coalesce(v_course ->> 'name', p_course.name),
        coalesce(v_course ->> 'school_level', p_course.school_level),
        case when v_course ? 'curriculum_code' then v_course ->> 'curriculum_code' else p_course.curriculum_code end
      );
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'op', 'course', 'text', '과정 정보 · ' || array_to_string(v_parts, ', ')
      ));
    else
      raise exception 'course_think_bad_op:%', v_n;
    end if;
  end loop;

  with recursive t as (
    select c.id, c.parent_id, c.name, array[c.pos] as path from course_think_units c where c.parent_id is null
    union all
    select c.id, c.parent_id, c.name, t.path || c.pos from course_think_units c join t on c.parent_id = t.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'parent_id', parent_id, 'name', name) order by path), '[]'::jsonb)
    into v_units
    from t;

  return jsonb_build_object(
    'units', v_units,
    'archive', to_jsonb(v_archive),
    'course', v_course,
    'lines', v_lines
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 개념 고치기 도우미(concept_library_change)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_think_name(p text)
returns text
language plpgsql
immutable
as $$
declare
  v text := btrim(coalesce(p, ''));
begin
  if v = '' or char_length(v) > 120 then
    raise exception 'concept_think_bad_name';
  end if;
  return v;
end;
$$;

create or replace function public.concept_think_content(p text)
returns text
language plpgsql
immutable
as $$
begin
  if p is null or btrim(p) = '' then
    raise exception 'concept_think_content_required';
  end if;
  if char_length(p) > 40000 then
    raise exception 'concept_think_too_long';
  end if;
  return btrim(p);
end;
$$;

-- 이미 있는 개념 유형만 쓴다(Think 카드로 새 유형을 만들지 않는다).
create or replace function public.concept_think_type(p text)
returns public.concept_types
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.concept_types;
begin
  select * into v from public.concept_types where lower(btrim(name)) = lower(btrim(coalesce(p, '')));
  if not found then
    raise exception 'concept_think_unknown_type';
  end if;
  return v;
end;
$$;

-- 폴더 경로(영역 루트부터 2~7칸)를 검사한다. 돌려줌 {path, new_from}: new_from 은 처음으로 없는 칸 번호(모두 있으면 null).
create or replace function public.concept_think_folder_check(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_path text[];
  v_seg text;
  v_parent uuid;
  v_cat uuid;
  v_n integer;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'concept_think_bad_folder';
  end if;
  if exists (select 1 from jsonb_array_elements(p) x where jsonb_typeof(x) <> 'string') then
    raise exception 'concept_think_bad_folder';
  end if;
  v_path := array(select btrim(x) from jsonb_array_elements_text(p) with ordinality as t(x, n) order by n);
  if cardinality(v_path) < 2 or cardinality(v_path) > 7 then
    raise exception 'concept_think_bad_folder';
  end if;
  foreach v_seg in array v_path loop
    if v_seg = '' or char_length(v_seg) > 80 then
      raise exception 'concept_think_bad_folder';
    end if;
  end loop;
  select id into v_parent
    from public.concept_categories
   where parent_id is null and name = v_path[1]
   order by sort_order, created_at
   limit 1;
  if v_parent is null then
    raise exception 'concept_think_unknown_root';
  end if;
  for v_n in 2 .. cardinality(v_path) loop
    v_cat := null;
    select id into v_cat
      from public.concept_categories
     where parent_id = v_parent and name = v_path[v_n] and coalesce(code, '') <> 'SHORTCUT'
     order by sort_order, created_at
     limit 1;
    if v_cat is null then
      return jsonb_build_object('path', to_jsonb(v_path), 'new_from', v_n);
    end if;
    v_parent := v_cat;
  end loop;
  return jsonb_build_object('path', to_jsonb(v_path), 'new_from', null);
end;
$$;

-- 경로의 마지막 폴더. 없는 칸은 개념 초안 확정과 같은 방식으로 만든다.
create or replace function public.concept_think_folder_make(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_path text[];
  v_parent uuid;
  v_parent_depth integer;
  v_cat uuid;
  v_n integer;
begin
  perform public.concept_think_folder_check(p);
  v_path := array(select btrim(x) from jsonb_array_elements_text(p) with ordinality as t(x, n) order by n);
  select id, depth into v_parent, v_parent_depth
    from public.concept_categories
   where parent_id is null and name = v_path[1]
   order by sort_order, created_at
   limit 1;
  for v_n in 2 .. cardinality(v_path) loop
    v_cat := null;
    select id into v_cat
      from public.concept_categories
     where parent_id = v_parent and name = v_path[v_n] and coalesce(code, '') <> 'SHORTCUT'
     order by sort_order, created_at
     limit 1;
    if v_cat is null then
      insert into public.concept_categories (name, parent_id, depth, sort_order)
      values (
        v_path[v_n], v_parent, v_parent_depth + 1,
        coalesce((select max(sort_order) + 1 from public.concept_categories where parent_id = v_parent), 0)
      )
      returning id into v_cat;
    end if;
    v_parent := v_cat;
    v_parent_depth := v_parent_depth + 1;
  end loop;
  return v_parent;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8) 제안(Think가 남김)
-- ─────────────────────────────────────────────────────────────────────────

-- 같은 대화에서 같은 과정을 기다리는 단원 바꾸기 제안은 새 제안으로 대체된다.
create or replace function public.course_think_propose_map(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_action text := nullif(btrim(coalesce(p_payload ->> 'course_action', '')), '');
  v_ops jsonb := p_payload -> 'ops';
  v_keys jsonb := '{}'::jsonb;
  v_op jsonb;
  v_key text;
  v_run jsonb;
  v_lines jsonb;
  v_kept integer := 0;
  v_out public.ai_actions;
begin
  select * into v_course from public.course_maps where id = public.course_think_uuid(p_payload ->> 'course_id');
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_ops is not null and jsonb_typeof(v_ops) = 'null' then
    v_ops := null;
  end if;

  if v_action is not null then
    if v_action not in ('archive', 'restore') then
      raise exception 'course_think_bad_op';
    end if;
    if v_ops is not null and (jsonb_typeof(v_ops) <> 'array' or jsonb_array_length(v_ops) > 0) then
      raise exception 'course_think_mixed';
    end if;
    if v_action = 'archive' and v_course.archived_at is not null then
      raise exception 'course_map_archived';
    end if;
    if v_action = 'restore' and v_course.archived_at is null then
      raise exception 'course_map_not_archived';
    end if;
    select count(*) into v_kept
      from public.concept_appearances a
      join public.course_map_units u on u.id = a.course_unit_id
     where u.course_id = v_course.id and u.archived_at is null;
    v_lines := jsonb_build_array(jsonb_build_object(
      'op', v_action,
      'text', case when v_action = 'archive'
        then format('과정 보관 · %s (단원과 놓인 개념 %s개는 지우지 않고 남깁니다)', v_course.name, v_kept)
        else format('과정 되살리기 · %s (목록 맨 끝에 붙습니다)', v_course.name) end
    ));
    v_ops := '[]'::jsonb;
    v_kept := 0;
  else
    if v_course.archived_at is not null then
      raise exception 'course_map_archived';
    end if;
    if v_ops is null or jsonb_typeof(v_ops) <> 'array' or jsonb_array_length(v_ops) = 0 then
      raise exception 'course_think_bad_ops';
    end if;
    for v_op in select e from jsonb_array_elements(v_ops) e loop
      if jsonb_typeof(v_op) = 'object' and v_op ->> 'op' = 'add' then
        v_key := btrim(coalesce(v_op ->> 'key', ''));
        if v_key = '' or char_length(v_key) > 40 or v_keys ? v_key then
          raise exception 'course_think_bad_key';
        end if;
        v_keys := v_keys || jsonb_build_object(v_key, gen_random_uuid());
      end if;
    end loop;
    -- 실제 저장까지 해 보고 되돌린다. 막히는 바꾸기는 카드가 되지 않는다.
    begin
      v_run := public.course_think_ops_run(v_course, v_ops, v_keys);
      perform public.course_map_save(
        v_course.id, v_course.version, v_run -> 'course', v_run -> 'units',
        array(select x::uuid from jsonb_array_elements_text(v_run -> 'archive') x)
      );
      raise exception 'course_think_dry_run';
    exception when others then
      if sqlerrm <> 'course_think_dry_run' then
        raise;
      end if;
    end;
    v_lines := v_run -> 'lines';
    select count(*) into v_kept
      from public.concept_appearances a
      join public.course_map_units u on u.id = a.course_unit_id
     where u.course_id = v_course.id and u.archived_at is null
       and not exists (select 1 from jsonb_array_elements(v_run -> 'units') x where (x ->> 'id')::uuid = u.id);
  end if;

  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id and kind = 'course_map_change' and status = 'proposed'
     and payload ->> 'course_id' = v_course.id::text;
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'course_map_change',
    jsonb_build_object(
      'course_id', v_course.id, 'base_version', v_course.version, 'ops', v_ops, 'keys', v_keys,
      'course_action', v_action, 'reason', p_reason
    ),
    jsonb_build_object(
      'title', case v_action when 'archive' then '과정 보관' when 'restore' then '과정 되살리기' else '과정 탐색도 고치기' end,
      'course_id', v_course.id, 'course_name', v_course.name, 'base_version', v_course.version,
      'lines', v_lines, 'archived_placements', v_kept, 'reason', p_reason
    )
  )
  returning * into v_out;
  return v_out;
end;
$$;

create or replace function public.course_think_propose_create(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_payload ->> 'name', ''));
  v_level text := p_payload ->> 'school_level';
  v_code text := nullif(btrim(coalesce(p_payload ->> 'curriculum_code', '')), '');
  v_units jsonb := coalesce(nullif(p_payload -> 'units', 'null'::jsonb), '[]'::jsonb);
  v_u jsonb;
  v_n integer := 0;
  v_key text;
  v_parent text;
  v_depth integer;
  v_unit_name text;
  v_keys jsonb := '{}'::jsonb;
  v_depths jsonb := '{}'::jsonb;
  v_save jsonb := '[]'::jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_tree jsonb;
  v_counts integer[] := array[0, 0, 0];
  v_new jsonb;
  v_out public.ai_actions;
begin
  perform public.course_map_check_course(v_name, v_level, v_code);
  if exists (select 1 from public.course_maps where lower(btrim(name)) = lower(v_name) and archived_at is null) then
    raise exception 'course_think_course_exists';
  end if;
  if exists (select 1 from public.course_maps where lower(btrim(name)) = lower(v_name)) then
    raise exception 'course_think_course_archived_exists';
  end if;
  if jsonb_typeof(v_units) <> 'array' then
    raise exception 'course_think_bad_ops';
  end if;
  if jsonb_array_length(v_units) > 300 then
    raise exception 'course_think_too_many';
  end if;

  drop table if exists pg_temp.course_think_units;
  create temp table course_think_units (
    id uuid primary key,
    parent_id uuid,
    name text not null,
    pos numeric not null,
    fresh boolean not null default false
  ) on commit drop;

  for v_u in select e from jsonb_array_elements(v_units) e loop
    v_n := v_n + 1;
    if jsonb_typeof(v_u) <> 'object' then
      raise exception 'course_think_bad_op:%', v_n;
    end if;
    v_key := btrim(coalesce(v_u ->> 'key', ''));
    if v_key = '' or char_length(v_key) > 40 or v_keys ? v_key then
      raise exception 'course_think_bad_key:%', v_n;
    end if;
    v_parent := nullif(btrim(coalesce(v_u ->> 'parent_key', '')), '');
    if v_parent is not null and not (v_keys ? v_parent) then
      raise exception 'course_think_unit_not_found:%', v_n;
    end if;
    v_depth := case when v_parent is null then 1 else (v_depths ->> v_parent)::integer + 1 end;
    if v_depth > 3 then
      raise exception 'course_think_too_deep:%', v_n;
    end if;
    v_unit_name := public.course_think_name(v_u ->> 'name', v_n);
    v_keys := v_keys || jsonb_build_object(v_key, gen_random_uuid());
    v_depths := v_depths || jsonb_build_object(v_key, v_depth);
    insert into course_think_units (id, parent_id, name, pos, fresh)
    values ((v_keys ->> v_key)::uuid, (v_keys ->> v_parent)::uuid, v_unit_name, v_n, true);
    v_save := v_save || jsonb_build_array(jsonb_build_object(
      'id', v_keys ->> v_key, 'parent_id', v_keys ->> v_parent, 'name', v_unit_name
    ));
    v_clean := v_clean || jsonb_build_array(jsonb_build_object('key', v_key, 'parent_key', v_parent, 'name', v_unit_name));
    v_counts[v_depth] := v_counts[v_depth] + 1;
  end loop;

  with recursive t as (
    select c.id, c.name, 1 as depth, array[c.pos] as path from course_think_units c where c.parent_id is null
    union all
    select c.id, c.name, t.depth + 1, t.path || c.pos from course_think_units c join t on c.parent_id = t.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('depth', depth, 'name', name) order by path), '[]'::jsonb)
    into v_tree
    from t;

  begin
    v_new := public.course_map_create(v_name, v_level, v_code);
    if jsonb_array_length(v_save) > 0 then
      perform public.course_map_save(
        (v_new -> 'course' ->> 'id')::uuid, (v_new -> 'course' ->> 'version')::integer, '{}'::jsonb, v_save, '{}'::uuid[]
      );
    end if;
    raise exception 'course_think_dry_run';
  exception when others then
    if sqlerrm <> 'course_think_dry_run' then
      raise;
    end if;
  end;

  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'course_map_create',
    jsonb_build_object(
      'name', v_name, 'school_level', v_level, 'curriculum_code', v_code, 'units', v_clean, 'keys', v_keys,
      'reason', p_reason
    ),
    jsonb_build_object(
      'title', '새 과정', 'name', v_name, 'school_level', v_level, 'curriculum_code', v_code,
      'curriculum_label', public.course_think_curriculum(v_code), 'units', v_tree, 'counts', to_jsonb(v_counts),
      'reason', p_reason
    )
  )
  returning * into v_out;
  return v_out;
end;
$$;

-- 항목 오류는 course_placement_bad_item:<몇 번째>:<이유>.
create or replace function public.course_think_propose_placement(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_items jsonb := p_payload -> 'items';
  v_item jsonb;
  v_i integer := 0;
  v_op text;
  v_unit public.course_map_units;
  v_row public.concept_appearances;
  v_concept public.concepts;
  v_basis text;
  v_evidence text;
  v_ids uuid[];
  v_pairs text[] := '{}'::text[];
  v_rows uuid[] := '{}'::uuid[];
  v_touched uuid[] := '{}'::uuid[];
  v_reordered uuid[] := '{}'::uuid[];
  v_clean jsonb := '[]'::jsonb;
  v_prev jsonb := '[]'::jsonb;
  v_counts jsonb := '{"place": 0, "move": 0, "remove": 0, "reorder": 0}'::jsonb;
  v_judgment integer := 0;
  v_units jsonb;
  v_out public.ai_actions;
begin
  select * into v_course from public.course_maps where id = public.course_think_uuid(p_payload ->> 'course_id');
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_course.archived_at is not null then
    raise exception 'course_map_archived';
  end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'course_placement_no_items';
  end if;
  if jsonb_array_length(v_items) > 50 then
    raise exception 'course_placement_too_many';
  end if;

  for v_item in select e from jsonb_array_elements(v_items) e loop
    v_i := v_i + 1;
    begin
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'course_placement_bad_op';
      end if;
      v_op := v_item ->> 'op';
      v_evidence := nullif(btrim(coalesce(v_item ->> 'evidence', '')), '');
      if char_length(coalesce(v_evidence, '')) > 300 then
        raise exception 'course_placement_evidence_too_long';
      end if;
      if v_op = 'place' then
        select * into v_concept from public.concepts where id = public.course_think_uuid(v_item ->> 'concept_id');
        if not found then
          raise exception 'course_placement_concept_not_found';
        end if;
        v_unit := public.course_placement_unit_in(public.course_think_uuid(v_item ->> 'unit_id'), v_course.id);
        if exists (
             select 1 from public.concept_appearances where course_unit_id = v_unit.id and concept_id = v_concept.id
           ) or (v_unit.id::text || ':' || v_concept.id::text) = any (v_pairs) then
          raise exception 'course_placement_exists';
        end if;
        v_basis := v_item ->> 'basis';
        if v_basis is null or v_basis not in ('source', 'judgment') then
          raise exception 'course_placement_bad_basis';
        end if;
        if v_evidence is null then
          raise exception 'course_placement_evidence_required';
        end if;
        if v_basis = 'source' and not public.concept_has_course_source(v_concept.id, v_course.course_key) then
          raise exception 'course_placement_no_source';
        end if;
        v_pairs := v_pairs || (v_unit.id::text || ':' || v_concept.id::text);
        v_touched := v_touched || v_unit.id;
        if v_basis = 'judgment' then
          v_judgment := v_judgment + 1;
        end if;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'place', 'concept_id', v_concept.id, 'unit_id', v_unit.id, 'basis', v_basis, 'evidence', v_evidence
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'place', 'concept_id', v_concept.id, 'concept_name', v_concept.name,
          'type', (
            select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
             where l.concept_id = v_concept.id
          ),
          'unit_id', v_unit.id, 'unit_path', array_to_string(public.course_unit_path(v_unit.id), ' › '),
          'basis', v_basis, 'evidence', v_evidence, 'elsewhere', public.concept_placement_paths(v_concept.id)
        ));
      elsif v_op = 'move' then
        v_row := public.course_placement_row_in(public.course_think_uuid(v_item ->> 'placement_id'), v_course.id);
        if v_row.id = any (v_rows) then
          raise exception 'course_placement_duplicate';
        end if;
        v_unit := public.course_placement_unit_in(public.course_think_uuid(v_item ->> 'unit_id'), v_course.id);
        if v_row.course_unit_id = v_unit.id then
          raise exception 'course_placement_same_unit';
        end if;
        if exists (
             select 1 from public.concept_appearances where course_unit_id = v_unit.id and concept_id = v_row.concept_id
           ) or (v_unit.id::text || ':' || v_row.concept_id::text) = any (v_pairs) then
          raise exception 'course_placement_exists';
        end if;
        v_rows := v_rows || v_row.id;
        v_pairs := v_pairs || (v_unit.id::text || ':' || v_row.concept_id::text);
        v_touched := v_touched || v_unit.id || v_row.course_unit_id;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'move', 'placement_id', v_row.id, 'unit_id', v_unit.id, 'evidence', v_evidence
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'move', 'placement_id', v_row.id, 'concept_id', v_row.concept_id,
          'concept_name', (select name from public.concepts where id = v_row.concept_id),
          'from_path', array_to_string(public.course_unit_path(v_row.course_unit_id), ' › '),
          'unit_id', v_unit.id, 'unit_path', array_to_string(public.course_unit_path(v_unit.id), ' › '),
          'evidence', v_evidence
        ));
      elsif v_op = 'remove' then
        v_row := public.course_placement_row_in(public.course_think_uuid(v_item ->> 'placement_id'), v_course.id);
        if v_row.id = any (v_rows) then
          raise exception 'course_placement_duplicate';
        end if;
        v_rows := v_rows || v_row.id;
        v_touched := v_touched || v_row.course_unit_id;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'remove', 'placement_id', v_row.id, 'evidence', v_evidence
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'remove', 'placement_id', v_row.id, 'concept_id', v_row.concept_id,
          'concept_name', (select name from public.concepts where id = v_row.concept_id),
          'from_path', array_to_string(public.course_unit_path(v_row.course_unit_id), ' › '),
          'evidence', v_evidence
        ));
      elsif v_op = 'reorder' then
        v_unit := public.course_placement_unit_in(public.course_think_uuid(v_item ->> 'unit_id'), v_course.id);
        if jsonb_typeof(v_item -> 'placement_ids') is distinct from 'array' then
          raise exception 'course_placement_stale';
        end if;
        v_ids := array(
          select public.course_think_uuid(x)
            from jsonb_array_elements_text(v_item -> 'placement_ids') with ordinality as t(x, n)
           order by n
        );
        if cardinality(v_ids) <> (select count(*) from public.concept_appearances where course_unit_id = v_unit.id)
           or cardinality(v_ids) <> (select count(distinct x) from unnest(v_ids) x where x is not null)
           or exists (
             select 1 from unnest(v_ids) x
              where not exists (
                select 1 from public.concept_appearances a where a.id = x and a.course_unit_id = v_unit.id
              )
           ) then
          raise exception 'course_placement_stale';
        end if;
        if v_unit.id = any (v_reordered) then
          raise exception 'course_placement_duplicate';
        end if;
        v_reordered := v_reordered || v_unit.id;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'reorder', 'unit_id', v_unit.id, 'placement_ids', to_jsonb(v_ids)
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'reorder', 'unit_id', v_unit.id,
          'unit_path', array_to_string(public.course_unit_path(v_unit.id), ' › '),
          'names', (
            select coalesce(jsonb_agg(c.name order by t.n), '[]'::jsonb)
              from unnest(v_ids) with ordinality as t(id, n)
              join public.concept_appearances a on a.id = t.id
              join public.concepts c on c.id = a.concept_id
          ),
          'evidence', v_evidence
        ));
      else
        raise exception 'course_placement_bad_op';
      end if;
      v_counts := jsonb_set(v_counts, array[v_op], to_jsonb((v_counts ->> v_op)::integer + 1));
    exception when others then
      raise exception 'course_placement_bad_item:%:%', v_i, sqlerrm;
    end;
  end loop;

  -- 순서를 바꾸는 단원은 같은 카드의 다른 항목이 건드리지 않아야 한다(승인 때 순서 목록이 어긋난다).
  if exists (select 1 from unnest(v_reordered) r where r = any (v_touched)) then
    raise exception 'course_placement_reorder_mixed';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x ->> 'id', 'depth', (x ->> 'depth')::integer,
           'path', array_to_string(public.course_unit_path((x ->> 'id')::uuid), ' › ')
         ) order by n), '[]'::jsonb)
    into v_units
    from jsonb_array_elements(public.course_map_units_json(v_course.id)) with ordinality as t(x, n);

  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'concept_placement_change',
    jsonb_build_object('course_id', v_course.id, 'items', v_clean, 'reason', p_reason),
    jsonb_build_object(
      'title', '개념 배치', 'course_id', v_course.id, 'course_name', v_course.name,
      'items', v_prev, 'units', v_units, 'counts', v_counts, 'judgment', v_judgment, 'reason', p_reason
    )
  )
  returning * into v_out;
  return v_out;
end;
$$;

-- 항목 오류는 concept_think_bad_item:<몇 번째>:<이유>. 붙은 것이 있는 지우기는 카드에 남기되 막힌 항목으로 표시한다.
create or replace function public.course_think_propose_library(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb := p_payload -> 'items';
  v_item jsonb;
  v_i integer := 0;
  v_op text;
  v_concept public.concepts;
  v_type public.concept_types;
  v_cur_type public.concept_types;
  v_name text;
  v_content text;
  v_folder jsonb;
  v_unit public.course_map_units;
  v_evidence text;
  v_st public.concept_statements;
  v_after jsonb;
  v_att jsonb;
  v_changes jsonb;
  v_before jsonb;
  v_seen uuid[] := '{}'::uuid[];
  v_seen_st uuid[] := '{}'::uuid[];
  v_clean jsonb := '[]'::jsonb;
  v_prev jsonb := '[]'::jsonb;
  v_counts jsonb := '{"create": 0, "edit": 0, "statement": 0, "delete": 0}'::jsonb;
  v_blocked integer := 0;
  v_out public.ai_actions;
begin
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'concept_think_no_items';
  end if;
  if jsonb_array_length(v_items) > 20 then
    raise exception 'concept_think_too_many';
  end if;

  for v_item in select e from jsonb_array_elements(v_items) e loop
    v_i := v_i + 1;
    begin
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'concept_think_bad_op';
      end if;
      v_op := v_item ->> 'op';
      if v_op = 'create' then
        v_name := public.concept_think_name(v_item ->> 'name');
        v_type := public.concept_think_type(v_item ->> 'type');
        v_folder := public.concept_think_folder_check(v_item -> 'folder');
        v_content := public.concept_think_content(v_item ->> 'content');
        v_evidence := nullif(btrim(coalesce(v_item ->> 'evidence', '')), '');
        v_unit := null;
        if nullif(btrim(coalesce(v_item ->> 'place_unit_id', '')), '') is not null then
          v_unit := public.course_placement_unit(public.course_think_uuid(v_item ->> 'place_unit_id'));
          if v_evidence is null then
            raise exception 'course_placement_evidence_required';
          end if;
        end if;
        if char_length(coalesce(v_evidence, '')) > 300 then
          raise exception 'course_placement_evidence_too_long';
        end if;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'create', 'name', v_name, 'type', v_type.name, 'folder', v_folder -> 'path', 'content', v_content,
          'place_unit_id', v_unit.id, 'evidence', v_evidence
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'create', 'name', v_name, 'type', v_type.name, 'folder', v_folder -> 'path',
          'new_from', v_folder -> 'new_from', 'content', v_content,
          'place', case when v_unit.id is null then null else jsonb_build_object(
            'unit_id', v_unit.id,
            'path', (select m.name from public.course_maps m where m.id = v_unit.course_id) || ' › '
                    || array_to_string(public.course_unit_path(v_unit.id), ' › ')
          ) end,
          'evidence', v_evidence,
          'same_name', (
            select coalesce(jsonb_agg(jsonb_build_object(
                     'id', c.id, 'name', c.name, 'folder', to_jsonb(public.concept_folder_path(c.main_category_id))
                   ) order by c.created_at), '[]'::jsonb)
              from (
                select * from public.concepts c0 where lower(btrim(c0.name)) = lower(v_name) order by c0.created_at limit 5
              ) c
          )
        ));
      elsif v_op = 'edit' then
        select * into v_concept from public.concepts where id = public.course_think_uuid(v_item ->> 'concept_id');
        if not found then
          raise exception 'concept_think_concept_not_found';
        end if;
        if v_concept.id = any (v_seen) then
          raise exception 'concept_think_duplicate';
        end if;
        v_seen := v_seen || v_concept.id;
        select t.* into v_cur_type
          from public.concept_type_links l join public.concept_types t on t.id = l.type_id
         where l.concept_id = v_concept.id;
        v_changes := '{}'::jsonb;
        v_before := '{}'::jsonb;
        if v_item ->> 'name' is not null then
          v_name := public.concept_think_name(v_item ->> 'name');
          if v_name <> v_concept.name then
            v_changes := v_changes || jsonb_build_object('name', v_name);
            v_before := v_before || jsonb_build_object('name', v_concept.name);
          end if;
        end if;
        if v_item ->> 'content' is not null then
          v_content := public.concept_think_content(v_item ->> 'content');
          if v_content <> v_concept.content then
            if exists (select 1 from public.concept_content_drafts where concept_id = v_concept.id) then
              raise exception 'concept_content_draft_pending';
            end if;
            v_changes := v_changes || jsonb_build_object('content', v_content);
            v_before := v_before || jsonb_build_object('content', v_concept.content);
          end if;
        end if;
        if v_item ->> 'type' is not null then
          v_type := public.concept_think_type(v_item ->> 'type');
          if v_cur_type.id is distinct from v_type.id then
            v_changes := v_changes || jsonb_build_object('type', v_type.name);
            v_before := v_before || jsonb_build_object('type', v_cur_type.name);
          end if;
        end if;
        if v_item -> 'folder' is not null and jsonb_typeof(v_item -> 'folder') <> 'null' then
          v_folder := public.concept_think_folder_check(v_item -> 'folder');
          if v_folder -> 'path' <> to_jsonb(public.concept_folder_path(v_concept.main_category_id)) then
            v_changes := v_changes || jsonb_build_object('folder', v_folder -> 'path', 'new_from', v_folder -> 'new_from');
            v_before := v_before || jsonb_build_object('folder', to_jsonb(public.concept_folder_path(v_concept.main_category_id)));
          end if;
        end if;
        if v_changes = '{}'::jsonb then
          raise exception 'concept_think_unchanged';
        end if;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'edit', 'concept_id', v_concept.id, 'changes', v_changes - 'new_from',
          'base', jsonb_build_object(
            'name', v_concept.name, 'md5', md5(v_concept.content), 'type_id', v_cur_type.id,
            'category_id', v_concept.main_category_id
          )
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'edit', 'concept_id', v_concept.id, 'name', v_concept.name,
          'before', v_before, 'after', v_changes
        ));
      elsif v_op = 'statement' then
        select * into v_st from public.concept_statements where id = public.course_think_uuid(v_item ->> 'statement_id');
        if not found then
          raise exception 'concept_statement_not_found';
        end if;
        if v_st.id = any (v_seen_st) then
          raise exception 'concept_think_duplicate';
        end if;
        v_seen_st := v_seen_st || v_st.id;
        if v_st.draft is not null then
          raise exception 'concept_statement_has_draft';
        end if;
        -- content 는 바꿀 칸만 담는다. 빠진 칸은 확정본 그대로, 빈 글은 그 칸을 비운다.
        if jsonb_typeof(v_item -> 'content') is distinct from 'object' then
          raise exception 'concept_statement_bad_content';
        end if;
        -- 인용·원문 조건 표시는 교재를 보고 사람이 적는 칸이다.
        if (v_item -> 'content') ?| array['quote', 'conditions_in_source'] then
          raise exception 'concept_think_source_field';
        end if;
        v_after := public.concept_statement_clean(v_st.role, coalesce(v_st.content, '{}'::jsonb) || (v_item -> 'content'));
        if v_after = v_st.content then
          raise exception 'concept_think_unchanged';
        end if;
        -- Think가 쓴 글을 원문 그대로(verbatim)로 표시하지 않는다. 원래 원문이던 서술의 본문·인용을 그대로 둘 때만 남는다.
        if v_st.role = 'statement' and v_after ->> 'basis' = 'verbatim'
           and (coalesce(v_st.content ->> 'basis', 'organized') <> 'verbatim'
                or (v_after ->> 'body') is distinct from (v_st.content ->> 'body')
                or (v_after ->> 'quote') is distinct from (v_st.content ->> 'quote')) then
          raise exception 'concept_think_verbatim';
        end if;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object(
          'op', 'statement', 'statement_id', v_st.id, 'content', v_after, 'base_version', v_st.version
        ));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'statement', 'statement_id', v_st.id, 'concept_id', v_st.concept_id,
          'concept_name', (select name from public.concepts where id = v_st.concept_id),
          'role', v_st.role, 'version', v_st.version, 'before', v_st.content, 'after', v_after
        ));
      elsif v_op = 'delete' then
        select * into v_concept from public.concepts where id = public.course_think_uuid(v_item ->> 'concept_id');
        if not found then
          raise exception 'concept_think_concept_not_found';
        end if;
        if v_concept.id = any (v_seen) then
          raise exception 'concept_think_duplicate';
        end if;
        v_seen := v_seen || v_concept.id;
        v_att := public.concept_attachments(v_concept.id);
        if (v_att ->> 'total')::integer > 0 then
          v_blocked := v_blocked + 1;
        end if;
        v_clean := v_clean || jsonb_build_array(jsonb_build_object('op', 'delete', 'concept_id', v_concept.id));
        v_prev := v_prev || jsonb_build_array(jsonb_build_object(
          'i', v_i, 'op', 'delete', 'concept_id', v_concept.id, 'name', v_concept.name,
          'type', (
            select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
             where l.concept_id = v_concept.id
          ),
          'folder', to_jsonb(public.concept_folder_path(v_concept.main_category_id)),
          'excerpt', left(regexp_replace(v_concept.content, '\s+', ' ', 'g'), 160),
          'attached', v_att, 'blocked', (v_att ->> 'total')::integer > 0
        ));
      else
        raise exception 'concept_think_bad_op';
      end if;
      v_counts := jsonb_set(v_counts, array[v_op], to_jsonb((v_counts ->> v_op)::integer + 1));
    exception when others then
      raise exception 'concept_think_bad_item:%:%', v_i, sqlerrm;
    end;
  end loop;

  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'concept_library_change',
    jsonb_build_object('items', v_clean, 'reason', p_reason),
    jsonb_build_object('title', '개념 고치기', 'items', v_prev, 'counts', v_counts, 'blocked', v_blocked, 'reason', p_reason)
  )
  returning * into v_out;
  return v_out;
end;
$$;

-- p_payload: course_map_change {course_id, ops, course_action, reason} · course_map_create {name, school_level,
--            curriculum_code, units, reason} · concept_placement_change {course_id, items, reason} ·
--            concept_library_change {items, reason}
create or replace function public.course_think_action_propose(p_conversation_id uuid, p_kind text, p_payload jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_reason text := left(btrim(coalesce(p_payload ->> 'reason', '')), 500);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if octet_length(v_payload::text) > 200000 then
    raise exception 'course_think_too_long';
  end if;
  if v_reason = '' then
    raise exception 'course_think_reason_required';
  end if;
  if p_kind = 'course_map_change' then
    return public.course_think_propose_map(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'course_map_create' then
    return public.course_think_propose_create(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_placement_change' then
    return public.course_think_propose_placement(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_library_change' then
    return public.course_think_propose_library(p_conversation_id, v_payload, v_reason);
  end if;
  raise exception 'action_kind_not_appliable' using errcode = '22023';
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9) 승인(운영자)
-- ─────────────────────────────────────────────────────────────────────────

-- 제안 때의 판 그대로일 때만 바꾼다. 그사이 과정이 바뀌었으면 course_map_stale 로 막고 카드는 기다리는 채로 남는다.
create or replace function public.course_think_apply_map(p_act public.ai_actions)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p jsonb := p_act.payload;
  v_course public.course_maps;
  v_version integer := (p_act.payload ->> 'base_version')::integer;
  v_run jsonb;
  v_res jsonb;
begin
  select * into v_course from public.course_maps where id = (v_p ->> 'course_id')::uuid for update;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_p ->> 'course_action' = 'archive' then
    perform public.course_map_archive(v_course.id, v_version);
    return jsonb_build_object('course_id', v_course.id, 'archived', true);
  elsif v_p ->> 'course_action' = 'restore' then
    if v_course.version <> v_version then
      raise exception 'course_map_stale';
    end if;
    perform public.course_map_restore(v_course.id);
    return jsonb_build_object('course_id', v_course.id, 'restored', true);
  end if;
  perform public.course_map_lock(v_course.id, v_version);
  v_run := public.course_think_ops_run(v_course, v_p -> 'ops', v_p -> 'keys');
  v_res := public.course_map_save(
    v_course.id, v_version, v_run -> 'course', v_run -> 'units',
    array(select x::uuid from jsonb_array_elements_text(v_run -> 'archive') x)
  );
  return jsonb_build_object(
    'course_id', v_course.id, 'version', v_res -> 'course' -> 'version', 'keys', v_p -> 'keys',
    'changes', jsonb_array_length(v_run -> 'lines')
  );
end;
$$;

create or replace function public.course_think_apply_create(p_act public.ai_actions)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p jsonb := p_act.payload;
  v_keys jsonb := coalesce(p_act.payload -> 'keys', '{}'::jsonb);
  v_new jsonb;
  v_id uuid;
  v_units jsonb;
begin
  v_new := public.course_map_create(v_p ->> 'name', v_p ->> 'school_level', v_p ->> 'curriculum_code');
  v_id := (v_new -> 'course' ->> 'id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v_keys ->> (u ->> 'key'), 'parent_id', v_keys ->> (u ->> 'parent_key'), 'name', u ->> 'name'
         ) order by n), '[]'::jsonb)
    into v_units
    from jsonb_array_elements(coalesce(v_p -> 'units', '[]'::jsonb)) with ordinality as t(u, n);
  if jsonb_array_length(v_units) > 0 then
    perform public.course_map_save(v_id, (v_new -> 'course' ->> 'version')::integer, '{}'::jsonb, v_units, '{}'::uuid[]);
  end if;
  return jsonb_build_object('course_id', v_id, 'units', jsonb_array_length(v_units));
end;
$$;

-- p_overrides {skip: [항목 번호], units: {"항목 번호": 단원 id}}. 항목 번호는 미리보기의 i(1부터).
create or replace function public.course_think_apply_placement(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_skip integer[];
  v_units jsonb := coalesce(nullif(p_overrides -> 'units', 'null'::jsonb), '{}'::jsonb);
  v_item jsonb;
  v_i integer := 0;
  v_unit uuid;
  v_id uuid;
  v_ids uuid[];
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  select * into v_course from public.course_maps where id = (p_act.payload ->> 'course_id')::uuid;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_course.archived_at is not null then
    raise exception 'course_map_archived';
  end if;
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;
  if jsonb_typeof(v_units) <> 'object' then
    raise exception 'course_think_bad_overrides';
  end if;

  for v_item in select e from jsonb_array_elements(p_act.payload -> 'items') e loop
    v_i := v_i + 1;
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      if v_units ? v_i::text then
        v_unit := public.course_think_uuid(v_units ->> v_i::text);
        if v_unit is null then
          raise exception 'course_think_bad_overrides';
        end if;
      else
        v_unit := public.course_think_uuid(v_item ->> 'unit_id');
      end if;
      v_id := null;
      case v_item ->> 'op'
        when 'place' then
          perform public.course_placement_unit_in(v_unit, v_course.id);
          v_id := public.course_placement_insert(v_unit, (v_item ->> 'concept_id')::uuid, 'ai', v_item ->> 'evidence');
        when 'move' then
          v_id := (v_item ->> 'placement_id')::uuid;
          perform public.course_placement_row_in(v_id, v_course.id);
          perform public.course_placement_unit_in(v_unit, v_course.id);
          perform public.course_placement_move_row(v_id, v_unit, 'ai', v_item ->> 'evidence');
        when 'remove' then
          v_id := (v_item ->> 'placement_id')::uuid;
          v_unit := (public.course_placement_row_in(v_id, v_course.id)).course_unit_id;
          delete from public.concept_appearances where id = v_id;
          perform public.course_placement_renumber(v_unit);
        when 'reorder' then
          perform public.course_placement_unit_in(v_unit, v_course.id);
          v_ids := array(
            select x::uuid from jsonb_array_elements_text(v_item -> 'placement_ids') with ordinality as t(x, n) order by n
          );
          perform public.course_placement_reorder_rows(v_unit, v_ids);
      end case;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'status', 'applied', 'placement_id', v_id, 'unit_id', v_unit
      ));
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200)));
    end;
  end loop;

  if v_applied = 0 then
    if v_failed = 0 then
      raise exception 'course_think_nothing_selected';
    end if;
    raise exception 'course_think_all_failed:%', v_first;
  end if;
  return jsonb_build_object(
    'course_id', v_course.id, 'items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
  );
end;
$$;

-- p_overrides {skip: [항목 번호]}.
create or replace function public.course_think_apply_library(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := left('Think 카드 승인: ' || coalesce(p_act.payload ->> 'reason', ''), 2000);
  v_skip integer[];
  v_item jsonb;
  v_i integer := 0;
  v_concept public.concepts;
  v_type public.concept_types;
  v_changes jsonb;
  v_base jsonb;
  v_cat uuid;
  v_family uuid;
  v_label text;
  v_n integer;
  v_id uuid;
  v_pid uuid;
  v_at timestamptz;
  v_att jsonb;
  v_snap jsonb;
  v_one jsonb;
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;

  for v_item in select e from jsonb_array_elements(p_act.payload -> 'items') e loop
    v_i := v_i + 1;
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      v_one := jsonb_build_object('i', v_i, 'status', 'applied');
      case v_item ->> 'op'
        when 'create' then
          v_type := public.concept_think_type(v_item ->> 'type');
          v_cat := public.concept_think_folder_make(v_item -> 'folder');
          insert into public.concept_families (canonical_name) values (v_item ->> 'name') on conflict (canonical_name) do nothing;
          select id into v_family from public.concept_families where canonical_name = v_item ->> 'name';
          v_label := '기본';
          v_n := 1;
          while exists (select 1 from public.concepts where family_id = v_family and version_label = v_label) loop
            v_n := v_n + 1;
            v_label := '기본-' || v_n;
          end loop;
          insert into public.concepts (kind, sub_type, name, content, level, main_category_id, sort_order, family_id, version_label)
          values (
            case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end,
            v_type.legacy_sub_type, v_item ->> 'name', v_item ->> 'content', 1, v_cat,
            coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_cat), 0),
            v_family, v_label
          )
          returning id into v_id;
          insert into public.concept_type_links (concept_id, type_id, created_by) values (v_id, v_type.id, auth.uid());
          v_pid := null;
          if public.course_think_uuid(v_item ->> 'place_unit_id') is not null then
            v_pid := public.course_placement_insert(
              (v_item ->> 'place_unit_id')::uuid, v_id, 'ai', v_item ->> 'evidence'
            );
          end if;
          v_one := v_one || jsonb_build_object('concept_id', v_id, 'placement_id', v_pid);
        when 'edit' then
          select * into v_concept from public.concepts where id = (v_item ->> 'concept_id')::uuid for update;
          if not found then
            raise exception 'concept_think_concept_not_found';
          end if;
          v_base := v_item -> 'base';
          if v_concept.name <> v_base ->> 'name'
             or md5(v_concept.content) <> v_base ->> 'md5'
             or v_concept.main_category_id <> (v_base ->> 'category_id')::uuid
             or (select type_id from public.concept_type_links where concept_id = v_concept.id)
                is distinct from (v_base ->> 'type_id')::uuid then
            raise exception 'concept_think_stale';
          end if;
          v_changes := v_item -> 'changes';
          if v_changes ? 'content'
             and exists (select 1 from public.concept_content_drafts where concept_id = v_concept.id) then
            raise exception 'concept_content_draft_pending';
          end if;
          if v_changes ? 'name' or v_changes ? 'content' then
            perform set_config('ygg.concept_content_via', 'draft', true);
            perform set_config('ygg.concept_content_note', v_note, true);
            perform set_config('ygg.concept_content_origin', 'ai', true);
            update public.concepts
               set name = coalesce(v_changes ->> 'name', name), content = coalesce(v_changes ->> 'content', content)
             where id = v_concept.id;
            perform set_config('ygg.concept_content_via', '', true);
            perform set_config('ygg.concept_content_note', '', true);
            perform set_config('ygg.concept_content_origin', '', true);
          end if;
          if v_changes ? 'type' then
            v_type := public.concept_think_type(v_changes ->> 'type');
            insert into public.concept_type_links (concept_id, type_id, created_by)
            values (v_concept.id, v_type.id, auth.uid())
            on conflict (concept_id) do update set type_id = excluded.type_id;
            update public.concepts
               set kind = case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end,
                   sub_type = v_type.legacy_sub_type
             where id = v_concept.id;
          end if;
          if v_changes ? 'folder' then
            v_cat := public.concept_think_folder_make(v_changes -> 'folder');
            update public.concepts
               set main_category_id = v_cat,
                   sort_order = coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_cat), 0)
             where id = v_concept.id and main_category_id <> v_cat;
          end if;
          v_one := v_one || jsonb_build_object('concept_id', v_concept.id);
        when 'statement' then
          perform public.concept_statement_lock(
            (v_item ->> 'statement_id')::uuid, (v_item ->> 'base_version')::integer, null
          );
          update public.concept_statements
             set draft = v_item -> 'content', draft_origin = 'ai', draft_saved_at = clock_timestamp(),
                 draft_saved_by = auth.uid()
           where id = (v_item ->> 'statement_id')::uuid
          returning draft_saved_at into v_at;
          perform public.concept_statement_confirm(
            (v_item ->> 'statement_id')::uuid, (v_item ->> 'base_version')::integer, v_at, v_note
          );
          v_one := v_one || jsonb_build_object('statement_id', v_item ->> 'statement_id');
        when 'delete' then
          select * into v_concept from public.concepts where id = (v_item ->> 'concept_id')::uuid for update;
          if not found then
            raise exception 'concept_think_concept_not_found';
          end if;
          v_att := public.concept_attachments(v_concept.id);
          if (v_att ->> 'total')::integer > 0 then
            raise exception 'concept_delete_attached';
          end if;
          v_snap := jsonb_build_object(
            'id', v_concept.id, 'name', v_concept.name, 'content', v_concept.content,
            'folder', to_jsonb(public.concept_folder_path(v_concept.main_category_id)),
            'type', (
              select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
               where l.concept_id = v_concept.id
            )
          );
          delete from public.concepts where id = v_concept.id;
          v_one := v_one || jsonb_build_object('deleted', v_snap);
      end case;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(v_one);
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200)));
    end;
  end loop;

  if v_applied = 0 then
    if v_failed = 0 then
      raise exception 'course_think_nothing_selected';
    end if;
    raise exception 'course_think_all_failed:%', v_first;
  end if;
  return jsonb_build_object('items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped);
end;
$$;

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
  if v_act.kind = 'course_map_change' then
    v_res := public.course_think_apply_map(v_act);
  elsif v_act.kind = 'course_map_create' then
    v_res := public.course_think_apply_create(v_act);
  elsif v_act.kind = 'concept_placement_change' then
    v_res := public.course_think_apply_placement(v_act, v_over);
  elsif v_act.kind = 'concept_library_change' then
    v_res := public.course_think_apply_library(v_act, v_over);
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 10) 기능 확인 (20261012120000 정의에 course_map_actions 추가)
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
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 11) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.course_think_uuid(text) from public, anon, authenticated;
revoke all on function public.course_think_level(integer) from public, anon, authenticated;
revoke all on function public.course_think_curriculum(text) from public, anon, authenticated;
revoke all on function public.course_think_name(text, integer) from public, anon, authenticated;
revoke all on function public.concept_think_name(text) from public, anon, authenticated;
revoke all on function public.concept_think_content(text) from public, anon, authenticated;
revoke all on function public.course_unit_path(uuid) from public, anon, authenticated;
revoke all on function public.concept_appearance_unit_fill() from public, anon, authenticated;
revoke all on function public.course_map_sync_appearances() from public, anon, authenticated;
revoke all on function public.concept_folder_path(uuid) from public, anon, authenticated;
revoke all on function public.concept_has_course_source(uuid, text) from public, anon, authenticated;
revoke all on function public.concept_placement_paths(uuid) from public, anon, authenticated;
revoke all on function public.course_placement_json(public.concept_appearances) from public, anon, authenticated;
revoke all on function public.concept_think_brief(uuid) from public, anon, authenticated;
revoke all on function public.concept_placement_pool(public.course_maps, text, text) from public, anon, authenticated;
revoke all on function public.concept_attachments(uuid) from public, anon, authenticated;
revoke all on function public.course_placement_unit(uuid) from public, anon, authenticated;
revoke all on function public.course_placement_unit_in(uuid, uuid) from public, anon, authenticated;
revoke all on function public.course_placement_row_in(uuid, uuid) from public, anon, authenticated;
revoke all on function public.course_placement_renumber(uuid) from public, anon, authenticated;
revoke all on function public.course_placement_insert(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.course_placement_move_row(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.course_placement_reorder_rows(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.course_think_ref(text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.course_think_path(uuid) from public, anon, authenticated;
revoke all on function public.course_think_depth(uuid) from public, anon, authenticated;
revoke all on function public.course_think_subtree(uuid) from public, anon, authenticated;
revoke all on function public.course_think_place(uuid, uuid, text, uuid, integer) from public, anon, authenticated;
revoke all on function public.course_think_ops_run(public.course_maps, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.concept_think_type(text) from public, anon, authenticated;
revoke all on function public.concept_think_folder_check(jsonb) from public, anon, authenticated;
revoke all on function public.concept_think_folder_make(jsonb) from public, anon, authenticated;
revoke all on function public.course_think_propose_map(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_propose_create(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_propose_placement(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_propose_library(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_apply_map(public.ai_actions) from public, anon, authenticated;
revoke all on function public.course_think_apply_create(public.ai_actions) from public, anon, authenticated;
revoke all on function public.course_think_apply_placement(public.ai_actions, jsonb) from public, anon, authenticated;
revoke all on function public.course_think_apply_library(public.ai_actions, jsonb) from public, anon, authenticated;

revoke all on function public.course_map_placements(uuid) from public, anon;
revoke all on function public.concept_placement_overview() from public, anon;
revoke all on function public.concept_placement_candidates(uuid, text, text, integer, integer) from public, anon;
revoke all on function public.concept_think_detail(uuid) from public, anon;
revoke all on function public.course_placement_add(uuid, uuid[]) from public, anon;
revoke all on function public.course_placement_remove(uuid) from public, anon;
revoke all on function public.course_placement_move(uuid, uuid) from public, anon;
revoke all on function public.course_placement_reorder(uuid, uuid[]) from public, anon;
revoke all on function public.course_think_action_propose(uuid, text, jsonb) from public, anon;
revoke all on function public.course_think_action_apply(uuid, jsonb) from public, anon;

grant execute on function public.course_map_placements(uuid) to authenticated;
grant execute on function public.concept_placement_overview() to authenticated;
grant execute on function public.concept_placement_candidates(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.concept_think_detail(uuid) to authenticated;
grant execute on function public.course_placement_add(uuid, uuid[]) to authenticated;
grant execute on function public.course_placement_remove(uuid) to authenticated;
grant execute on function public.course_placement_move(uuid, uuid) to authenticated;
grant execute on function public.course_placement_reorder(uuid, uuid[]) to authenticated;
grant execute on function public.course_think_action_propose(uuid, text, jsonb) to authenticated;
grant execute on function public.course_think_action_apply(uuid, jsonb) to authenticated;
