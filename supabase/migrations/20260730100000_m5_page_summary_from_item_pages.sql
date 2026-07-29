-- 그룹 page_summary: 하위과제 page 가 비어도 homework_item_pages 로 복원.
--
-- 학습앱은 unitMappings(← homework_item_pages)로 클라이언트에서 페이지를
-- 다시 계산한다. 학생앱/M5 목록 RPC 는 h.page 만 보고 있어서 같은 과제가
-- 페이지 없이 내려갔다. 서버 page_summary(및 children.page)에
-- homework_item_pages 를 합쳐 학습앱과 동일하게 보이게 한다.

create or replace function public.m5_group_page_summary_from_items(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_ids uuid[],
  p_page_texts text[]
)
returns text
language sql
stable
set search_path = public
as $$
  select public.m5_compress_page_summary(
    coalesce(p_page_texts, array[]::text[])
    || coalesce(
         (
           select array_agg(p.page_number::text order by p.page_number)
           from public.homework_item_pages p
           where p.academy_id = p_academy_id
             and p.student_id = p_student_id
             and p.homework_item_id = any(coalesce(p_item_ids, array[]::uuid[]))
         ),
         array[]::text[]
       )
  );
$$;

revoke all on function public.m5_group_page_summary_from_items(uuid, uuid, uuid[], text[])
  from public;
grant execute on function public.m5_group_page_summary_from_items(uuid, uuid, uuid[], text[])
  to anon, authenticated;

-- 하위 1건의 page 가 비었을 때 homework_item_pages 로 채운다.
create or replace function public.m5_item_page_text_from_stats(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_id uuid,
  p_page text
)
returns text
language sql
stable
set search_path = public
as $$
  select coalesce(
    nullif(trim(coalesce(p_page, '')), ''),
    public.m5_compress_page_summary(
      (
        select array_agg(p.page_number::text order by p.page_number)
        from public.homework_item_pages p
        where p.academy_id = p_academy_id
          and p.student_id = p_student_id
          and p.homework_item_id = p_item_id
      )
    ),
    ''
  );
$$;

revoke all on function public.m5_item_page_text_from_stats(uuid, uuid, uuid, text)
  from public;
grant execute on function public.m5_item_page_text_from_stats(uuid, uuid, uuid, text)
  to anon, authenticated;

-- 목록 RPC: page_summary / children.page 에 item_pages 반영
create or replace function public.m5_list_homework_groups(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb
) as $$
begin
  return query
  with active_items as (
    select
      gi.group_id,
      gi.item_order_index,
      h.id as item_id,
      h.title,
      h.page,
      h."count",
      h.memo,
      coalesce(h.check_count, 0)::integer as check_count,
      h.color::bigint as color,
      coalesce(h.phase, 1)::smallint as phase,
      (coalesce(h.accumulated_ms, 0) / 1000)::bigint as accumulated,
      (
        (
          case
            when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                 and coalesce(h.phase, 1) = 1
                 and coalesce(h.accumulated_ms, 0) > 0
              then coalesce(h.accumulated_ms, 0)
            else coalesce(h.cycle_base_accumulated_ms, 0)
          end
        ) / 1000
      )::bigint as cycle_base_sec,
      greatest(
        0::bigint,
        (
          (
            coalesce(h.accumulated_ms, 0)
            -
            case
              when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                   and coalesce(h.phase, 1) = 1
                   and coalesce(h.accumulated_ms, 0) > 0
                then coalesce(h.accumulated_ms, 0)
              else coalesce(h.cycle_base_accumulated_ms, 0)
            end
          ) / 1000
        )::bigint
      ) as cycle_elapsed_sec,
      h.run_start,
      h.first_started_at,
      h.content,
      h.book_id::text as book_id,
      h.grade_label,
      h."type",
      coalesce(h.time_limit_minutes, 0)::integer as time_limit_minutes,
      h.submitted_at,
      h.confirmed_at,
      h.waiting_at,
      nullif(
        trim(
          concat_ws(
            ' ',
            nullif(
              regexp_replace(
                trim(
                  coalesce(
                    doc.exam_year::text,
                    doc.meta #>> '{source_classification,naesin,year}',
                    ''
                  )
                ),
                '[^0-9]',
                '',
                'g'
              ),
              ''
            ),
            nullif(
              trim(regexp_replace(trim(coalesce(doc.school_name, '')), '학교$', '')),
              ''
            ),
            nullif(
              trim(
                coalesce(
                  nullif(trim(doc.grade_label), ''),
                  nullif(trim(h.grade_label), '')
                )
              ),
              ''
            ),
            nullif(trim(doc.semester_label), ''),
            nullif(trim(doc.exam_term_label), ''),
            nullif(
              coalesce(
                nullif(trim(rf.name), ''),
                nullif(trim(doc.material_name), ''),
                nullif(trim(h.title), '')
              ),
              ''
            )
          )
        ),
        ''
      ) as m5_wait_title
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    left join public.pb_export_presets pr
      on pr.id = h.pb_preset_id
     and pr.academy_id = h.academy_id
    left join public.pb_documents doc
      on doc.academy_id = h.academy_id
     and doc.id = coalesce(pr.source_document_id, pr.document_id)
    left join public.resource_files rf
      on rf.id = h.book_id
     and rf.academy_id = h.academy_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) between 1 and 4
      and not exists (
        select 1
        from public.homework_assignments a
        where a.homework_item_id = h.id
          and a.academy_id = p_academy_id
          and a.student_id = p_student_id
          and a.status = 'assigned'
      )
  ),
  group_summary as (
    select
      g.id as group_id,
      g.title as group_title,
      g.order_index,
      case
        when bool_or(ai.run_start is not null) then 2::smallint
        when bool_or(ai.phase = 3) then 3::smallint
        when bool_or(ai.phase = 4) then 4::smallint
        else greatest(max(ai.phase), 1)::smallint
      end as phase,
      (sum(ai.cycle_base_sec) + coalesce(max(ai.cycle_elapsed_sec), 0))::bigint as accumulated,
      coalesce(max(ai.cycle_elapsed_sec), 0)::bigint as cycle_elapsed,
      max(ai.check_count)::integer as check_count,
      sum(coalesce(ai."count", 0))::integer as total_count,
      (array_agg(ai.color order by ai.item_order_index))[1] as color,
      public.m5_group_page_summary_from_items(
        p_academy_id,
        p_student_id,
        array_agg(ai.item_id order by ai.item_order_index),
        array_agg(ai.page order by ai.item_order_index)
      ) as page_summary,
      (array_agg(ai.run_start order by ai.item_order_index) filter (where ai.run_start is not null))[1] as run_start,
      min(ai.first_started_at) as first_started_at,
      (array_agg(ai.content order by ai.item_order_index))[1] as content,
      (array_agg(ai.book_id order by ai.item_order_index))[1] as book_id,
      (array_agg(ai.grade_label order by ai.item_order_index))[1] as grade_label,
      (array_agg(ai."type" order by ai.item_order_index))[1] as "type",
      coalesce((array_agg(ai.time_limit_minutes order by ai.item_order_index))[1], 0)::integer as time_limit_minutes,
      (array_agg(ai.m5_wait_title order by ai.item_order_index))[1] as m5_wait_title,
      jsonb_agg(
        jsonb_build_object(
          'item_id', ai.item_id,
          'title', ai.title,
          'page', public.m5_item_page_text_from_stats(
            p_academy_id, p_student_id, ai.item_id, ai.page
          ),
          'count', ai."count",
          'memo', ai.memo,
          'check_count', ai.check_count,
          'phase', ai.phase,
          'accumulated', ai.accumulated,
          'run_start', ai.run_start
        ) order by ai.item_order_index
      ) as children
    from public.homework_groups g
    join active_items ai on ai.group_id = g.id
    where g.academy_id = p_academy_id
      and g.student_id = p_student_id
      and g.status = 'active'
    group by g.id, g.title, g.order_index
  )
  select
    gs.group_id,
    gs.group_title,
    gs.order_index,
    coalesce(gr.phase, gs.phase)::smallint as phase,
    case
      when gr.phase is null then gs.accumulated
      else (
        coalesce(gr.accumulated_ms, 0)
        + case
            when gr.phase = 2 and gr.run_start is not null
              then greatest(0, floor(extract(epoch from (now() - gr.run_start)) * 1000)::bigint)
            else 0
          end
      ) / 1000
    end::bigint as accumulated,
    (
      gs.cycle_elapsed
      + case
          when gr.phase = 2 and gr.run_start is not null
            then greatest(0, floor(extract(epoch from (now() - gr.run_start)))::bigint)
          else 0::bigint
        end
    )::bigint as cycle_elapsed,
    coalesce(gr.check_count, gs.check_count)::integer as check_count,
    gs.total_count,
    gs.color,
    gs.page_summary,
    case
      when gr.phase = 2 then gr.run_start
      when gr.phase is null then gs.run_start
      else null
    end as run_start,
    coalesce(gr.first_started_at, gs.first_started_at) as first_started_at,
    gs.content,
    gs.book_id,
    gs.grade_label,
    gs."type",
    gs.time_limit_minutes,
    gs.m5_wait_title,
    case
      when gr.phase is null or gs.children is null then gs.children
      else (
        select jsonb_agg(
          jsonb_set(
            jsonb_set(
              child_elem,
              '{phase}',
              to_jsonb(gr.phase::integer),
              true
            ),
            '{run_start}',
            case
              when gr.phase = 2 and gr.run_start is not null
                then to_jsonb(gr.run_start)
              else 'null'::jsonb
            end,
            true
          )
        )
        from jsonb_array_elements(gs.children) as child_elem
      )
    end as children
  from group_summary gs
  left join public.homework_group_runtime gr
    on gr.academy_id = p_academy_id
   and gr.group_id = gs.group_id
   and gr.student_id = p_student_id
  order by gs.order_index asc, gs.group_id asc
  limit 8;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homework_groups(uuid, uuid) to anon, authenticated;

-- Re-define m5_list_homework_only_groups with the union-compressed page_summary.
-- (Body copied from 20260529215000_m5_list_homework_only_groups_fix.sql;
--  only the page_summary expression changed.)
create or replace function public.m5_list_homework_only_groups(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb
) as $$
begin
  return query
  with hw_items as (
    select
      gi.group_id,
      gi.item_order_index,
      h.id as item_id,
      h.title,
      h.page,
      h."count",
      h.memo,
      coalesce(h.check_count, 0)::integer as check_count,
      h.color::bigint as color,
      h.content,
      h.book_id::text as book_id,
      h.grade_label,
      h."type"
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and exists (
        select 1
        from public.homework_assignments a
        where a.homework_item_id = h.id
          and a.academy_id = p_academy_id
          and a.student_id = p_student_id
          and a.status = 'assigned'
      )
  ),
  active_group_ids as (
    select distinct gi.group_id
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) between 1 and 4
      and not exists (
        select 1
        from public.homework_assignments a
        where a.homework_item_id = h.id
          and a.academy_id = p_academy_id
          and a.student_id = p_student_id
          and a.status = 'assigned'
      )
  )
  select
    g.id as group_id,
    g.title as group_title,
    g.order_index,
    1::smallint as phase,
    0::bigint as accumulated,
    0::bigint as cycle_elapsed,
    max(hi.check_count)::integer as check_count,
    sum(coalesce(hi."count", 0))::integer as total_count,
    (array_agg(hi.color order by hi.item_order_index))[1] as color,
    public.m5_group_page_summary_from_items(
      p_academy_id,
      p_student_id,
      array_agg(hi.item_id order by hi.item_order_index),
      array_agg(hi.page order by hi.item_order_index)
    ) as page_summary,
    null::timestamptz as run_start,
    null::timestamptz as first_started_at,
    (array_agg(hi.content order by hi.item_order_index))[1] as content,
    (array_agg(hi.book_id order by hi.item_order_index))[1] as book_id,
    (array_agg(hi.grade_label order by hi.item_order_index))[1] as grade_label,
    (array_agg(hi."type" order by hi.item_order_index))[1] as "type",
    0::integer as time_limit_minutes,
    null::text as m5_wait_title,
    jsonb_agg(
      jsonb_build_object(
        'item_id', hi.item_id,
        'title', hi.title,
        'page', public.m5_item_page_text_from_stats(
          p_academy_id, p_student_id, hi.item_id, hi.page
        ),
        'count', hi."count",
        'memo', hi.memo,
        'check_count', hi.check_count,
        'phase', 1,
        'accumulated', 0,
        'run_start', null
      ) order by hi.item_order_index
    ) as children
  from public.homework_groups g
  join hw_items hi on hi.group_id = g.id
  where g.academy_id = p_academy_id
    and g.student_id = p_student_id
    and g.status = 'active'
    and not exists (select 1 from active_group_ids agi where agi.group_id = g.id)
  group by g.id, g.title, g.order_index
  order by g.order_index asc, g.id asc
  limit 6;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homework_only_groups(uuid, uuid) to anon, authenticated;
