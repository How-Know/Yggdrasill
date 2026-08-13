-- 20260813170000: 포인트 내역 RPC 조회 실패 수정
--
-- 원인: JOIN ON 의 source_id::uuid 가 출석 행까지 평가되면
--       uuid가 아닌 source_id 에서 예외가 난다.
-- 조인은 텍스트 비교로 바꾸고, problem_count 캐스트도 numeric 경유로 안전하게 한다.

create or replace function public.student_list_recent_points_v1(
  p_limit integer default 20
)
returns table(
  id text,
  created_at timestamptz,
  kind text,
  delta integer,
  title text,
  detail text,
  group_id uuid,
  children jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_limit integer := greatest(least(coalesce(p_limit, 20), 50), 1);
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with base as (
    select
      l.id as ledger_id,
      l.created_at as ledger_at,
      l.kind as ledger_kind,
      l.delta as ledger_delta,
      gi.group_id as item_group_id,
      gi.item_order_index,
      case
        when jsonb_typeof(l.basis -> 'problem_count') = 'number'
        then (l.basis ->> 'problem_count')::numeric::integer
        else 0
      end as problem_count,
      case l.kind
        when 'earn_homework' then
          coalesce(
            nullif(nullif(btrim(hg.title), ''), '과제 그룹'),
            nullif(btrim(h.title), ''),
            nullif(btrim(rf.name), ''),
            '과제 완료'
          )
        when 'earn_attendance' then
          coalesce(nullif(btrim(l.basis->>'class_name'), ''), '출석')
        when 'earn_bonus' then '보너스'
        else coalesce(nullif(btrim(l.memo), ''), '포인트')
      end as group_title,
      case l.kind
        when 'earn_homework' then
          coalesce(
            case
              when nullif(btrim(h.page), '') is not null
              then 'p.' || btrim(h.page)
              else null
            end,
            nullif(btrim(h.title), ''),
            '하위과제'
          )
        else
          coalesce(nullif(btrim(l.basis->>'class_name'), ''), '출석')
      end as item_title,
      public._student_point_history_detail(l.kind, l.basis) as item_detail
    from public.student_point_ledger l
    left join public.homework_items h
      on l.kind = 'earn_homework'
     and l.source_type = 'homework_item'
     and h.id::text = l.source_id
     and h.academy_id = v_academy
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = v_academy
    left join public.homework_groups hg
      on hg.id = gi.group_id
     and hg.academy_id = v_academy
    left join public.resource_files rf
      on rf.id = h.book_id
     and rf.academy_id = v_academy
    where l.academy_id = v_academy
      and l.student_id = v_student
      and l.delta > 0
      and l.kind in ('earn_homework', 'earn_attendance', 'earn_bonus')
  ),
  recent as (
    select *
    from base
    order by ledger_at desc, ledger_id desc
    limit 100
  ),
  needed_groups as (
    select distinct r.item_group_id
    from recent r
    where r.ledger_kind = 'earn_homework'
      and r.item_group_id is not null
  ),
  rows as (
    select b.*
    from base b
    where b.ledger_id in (select r.ledger_id from recent r)
       or (
         b.ledger_kind = 'earn_homework'
         and b.item_group_id in (select g.item_group_id from needed_groups g)
       )
  ),
  tagged as (
    select
      r.*,
      case
        when r.ledger_kind = 'earn_homework' and r.item_group_id is not null
        then 'g:' || r.item_group_id::text
        else 'l:' || r.ledger_id::text
      end as bucket_id
    from rows r
  ),
  show_buckets as (
    select distinct
      case
        when r.ledger_kind = 'earn_homework' and r.item_group_id is not null
        then 'g:' || r.item_group_id::text
        else 'l:' || r.ledger_id::text
      end as bucket_id
    from recent r
  ),
  agg as (
    select
      t.bucket_id as row_id,
      max(t.ledger_at) as row_created_at,
      max(t.ledger_kind) as row_kind,
      sum(t.ledger_delta)::integer as row_delta,
      max(t.group_title) as row_title,
      case
        when max(t.ledger_kind) <> 'earn_homework' then max(t.item_detail)
        when count(*) = 1 then max(t.item_detail)
        else
          '하위과제 ' || count(*)::text || '개'
          || case
            when coalesce(sum(t.problem_count), 0) > 0
            then ' · 문항 ' || sum(t.problem_count)::integer::text || '개'
            else ''
          end
      end as row_detail,
      (array_agg(t.item_group_id) filter (where t.item_group_id is not null))[1]
        as row_group_id,
      case
        when max(t.ledger_kind) = 'earn_homework' then
          coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id', t.ledger_id::text,
                'created_at', t.ledger_at,
                'delta', t.ledger_delta,
                'title', t.item_title,
                'detail', t.item_detail
              )
              order by t.item_order_index nulls last, t.ledger_at, t.ledger_id
            ),
            '[]'::jsonb
          )
        else '[]'::jsonb
      end as row_children
    from tagged t
    where t.bucket_id in (select s.bucket_id from show_buckets s)
    group by t.bucket_id
  )
  select
    a.row_id,
    a.row_created_at,
    a.row_kind,
    a.row_delta,
    a.row_title,
    a.row_detail,
    a.row_group_id,
    a.row_children
  from agg a
  order by a.row_created_at desc, a.row_id desc
  limit v_limit;
end;
$$;

revoke all on function public.student_list_recent_points_v1(integer) from public;
grant execute on function public.student_list_recent_points_v1(integer)
  to authenticated;

notify pgrst, 'reload schema';
