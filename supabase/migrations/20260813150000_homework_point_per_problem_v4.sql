-- 20260813150000: 과제 포인트 문항 단위 + 내역 그룹 묶음 (point_rule_v4)
--
-- v3는 하위과제(homework_item) 1건당 기본 10P였다. 그룹 하나에 하위과제가
-- 여러 개면 한 번 완료에 수십 P가 나갔다.
--
-- v4는 문항당 기본 10P. 난이도 차등은 나중에 points_per_problem 만 바꾸면 된다.
-- 시간/검사 보너스는 문항 단가에 붙인 뒤 문항 수를 곱한다.
--   per = 10 + time_bonus(0~6) + check_bonus(0~4)
--   base = problem_count × per
--
-- 목록 RPC는 그룹과제 단위로 합산하고, 하위과제 내역은 children 으로 내려 준다.

create or replace function public._grant_homework_completion_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_minutes numeric;
  v_recommended numeric;
  v_is_migrated boolean;
  v_too_fast boolean;
  v_time_bonus numeric;
  v_check_bonus numeric;
  v_checks integer;
  v_n integer;
  v_per numeric;
  v_base numeric;
  v_booster numeric;
  v_points integer;
  v_time_reason text;
  v_completed_at timestamptz;
  v_group_id uuid;
  v_points_per_problem numeric := 10.0;
begin
  if new.student_id is null or new.academy_id is null then
    return new;
  end if;

  select gi.group_id
    into v_group_id
  from public.homework_group_items gi
  where gi.homework_item_id = new.id
    and gi.academy_id = new.academy_id
  limit 1;

  select count(*)::integer
    into v_n
  from public.homework_item_problems p
  where p.homework_item_id = new.id
    and p.academy_id = new.academy_id;

  v_n := greatest(coalesce(nullif(v_n, 0), new.count), 1);

  v_minutes := coalesce(new.accumulated_ms, 0)::numeric / 60000.0;
  v_recommended := coalesce(new.recommended_minutes, new.recommended_minutes_auto)::numeric;
  v_completed_at := coalesce(new.completed_at, now());
  v_too_fast := (v_completed_at <= new.created_at + interval '5 minutes');

  v_is_migrated := exists (
    select 1
    from public.homework_item_problems p
    where p.homework_item_id = new.id
      and p.academy_id = new.academy_id
  );

  if not v_is_migrated then
    v_time_bonus := 0;
    v_time_reason := 'legacy';
  elsif v_recommended is null or v_recommended <= 0 then
    v_time_bonus := 0;
    v_time_reason := 'no_recommended';
  elsif v_too_fast then
    v_time_bonus := 0;
    v_time_reason := 'too_fast';
  elsif coalesce(new.accumulated_ms, 0) <= 0 then
    v_time_bonus := 0;
    v_time_reason := 'no_elapsed';
  elsif v_minutes >= v_recommended then
    v_time_bonus := 0;
    v_time_reason := 'over_recommended';
  else
    v_time_bonus := (1.0 - (v_minutes / v_recommended)) * 6.0;
    v_time_reason := 'within_recommended';
  end if;

  v_checks := coalesce(new.check_count, 0);
  v_check_bonus := case
    when v_checks <= 1 then 4.0
    when v_checks = 2 then 4.0 * 2.0 / 3.0
    when v_checks = 3 then 4.0 * 1.0 / 3.0
    else 0.0
  end;

  v_per := v_points_per_problem + v_time_bonus + v_check_bonus;
  v_base := v_n::numeric * v_per;
  v_booster := public._booster_for_v1(new.academy_id, new.student_id)::numeric;
  v_points := greatest(round(v_base * v_booster)::integer, 1);

  perform public._point_grant_internal(
    new.academy_id,
    new.student_id,
    v_points,
    'earn_homework',
    'homework_item',
    new.id::text,
    'point_rule_v4',
    jsonb_build_object(
      'accumulated_ms', coalesce(new.accumulated_ms, 0),
      'minutes', round(v_minutes, 2),
      'recommended_minutes', v_recommended,
      'is_migrated', v_is_migrated,
      'too_fast', v_too_fast,
      'time_bonus_reason', v_time_reason,
      'check_count', v_checks,
      'problem_count', v_n,
      'points_per_problem', v_points_per_problem,
      'per_problem', round(v_per, 2),
      'base', round(v_base, 2),
      'time_bonus', round(v_time_bonus, 2),
      'check_bonus', round(v_check_bonus, 2),
      'time_bonus_total', round(v_time_bonus * v_n, 2),
      'check_bonus_total', round(v_check_bonus * v_n, 2),
      'booster', round(v_booster, 4),
      'group_id', v_group_id,
      'completed_at', v_completed_at,
      'created_at', new.created_at,
      'book_id', new.book_id,
      'grade_label', new.grade_label,
      'flow_id', new.flow_id
    ),
    null::text,
    null::uuid
  );

  return new;
end;
$$;

create or replace function public._student_point_history_detail(
  p_kind text,
  p_basis jsonb
)
returns text
language plpgsql
immutable
as $$
declare
  v_basis jsonb := coalesce(p_basis, '{}'::jsonb);
  v_parts text[] := '{}';
  v_time numeric;
  v_check numeric;
  v_checks integer;
  v_reason text;
  v_booster numeric;
  v_late boolean;
  v_n integer;
  v_unit numeric;
  v_has_n boolean;
begin
  if p_kind = 'earn_attendance' then
    v_late := coalesce((v_basis->>'is_late')::boolean, false);
    if v_late then
      v_parts := array['지각 출석', '기본 12P'];
    else
      v_parts := array['정시 출석', '기본 20P'];
    end if;
    v_booster := nullif(v_basis->>'booster', '')::numeric;
    if v_booster is not null and v_booster >= 1.08 then
      v_parts := v_parts || '성적이 좋아서 더 받음'::text;
    end if;
    return array_to_string(v_parts, ' · ');
  end if;

  if p_kind = 'earn_homework' then
    v_has_n := (v_basis ? 'problem_count');
    v_n := greatest(coalesce(nullif(v_basis->>'problem_count', '')::integer, 1), 1);
    v_unit := coalesce(nullif(v_basis->>'points_per_problem', '')::numeric, 10);
    v_time := coalesce(nullif(v_basis->>'time_bonus', '')::numeric, 0);
    v_check := coalesce(nullif(v_basis->>'check_bonus', '')::numeric, 0);
    v_checks := coalesce(nullif(v_basis->>'check_count', '')::integer, 0);
    v_reason := coalesce(v_basis->>'time_bonus_reason', '');
    v_booster := nullif(v_basis->>'booster', '')::numeric;

    if v_has_n then
      v_parts := array[
        '문항 ' || v_n::text || '개',
        '기본 ' || round(v_n::numeric * v_unit)::integer::text || 'P'
      ];
      if v_time >= 0.5 then
        if v_reason = 'within_recommended' then
          v_parts := v_parts || (
            '빨리 끝내서 +' || round(v_time * v_n)::integer::text
          );
        else
          v_parts := v_parts || (
            '수행 시간 +' || round(v_time * v_n)::integer::text
          );
        end if;
      end if;
      if v_check >= 0.5 then
        if v_checks <= 1 then
          v_parts := v_parts || (
            '한 번에 통과해서 +' || round(v_check * v_n)::integer::text
          );
        else
          v_parts := v_parts || (
            '검사 ' || v_checks::text || '회로 +'
            || round(v_check * v_n)::integer::text
          );
        end if;
      end if;
    else
      v_parts := array['기본 10P'];
      if v_time >= 0.5 then
        if v_reason = 'within_recommended' then
          v_parts := v_parts || ('빨리 끝내서 +' || round(v_time)::integer::text);
        else
          v_parts := v_parts || ('수행 시간 +' || round(v_time)::integer::text);
        end if;
      end if;
      if v_check >= 0.5 then
        if v_checks <= 1 then
          v_parts := v_parts || ('한 번에 통과해서 +' || round(v_check)::integer::text);
        else
          v_parts := v_parts || (
            '검사 ' || v_checks::text || '회로 +' || round(v_check)::integer::text
          );
        end if;
      end if;
    end if;

    if v_booster is not null and v_booster >= 1.08 then
      v_parts := v_parts || '성적이 좋아서 더 받음'::text;
    end if;

    return array_to_string(v_parts, ' · ');
  end if;

  if p_kind = 'earn_bonus' then
    return '보너스';
  end if;

  return '';
end;
$$;

revoke all on function public._student_point_history_detail(text, jsonb) from public;

drop function if exists public.student_list_recent_points_v1(integer);

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
      l.created_at,
      l.kind,
      l.delta,
      l.basis,
      gi.group_id,
      gi.item_order_index,
      coalesce((l.basis->>'problem_count')::integer, 0) as problem_count,
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
     and l.source_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     and h.id = l.source_id::uuid
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
    order by created_at desc, ledger_id desc
    limit 100
  ),
  needed_groups as (
    select distinct r.group_id
    from recent r
    where r.kind = 'earn_homework'
      and r.group_id is not null
  ),
  rows as (
    select b.*
    from base b
    where b.ledger_id in (select r.ledger_id from recent r)
       or (b.kind = 'earn_homework' and b.group_id in (select g.group_id from needed_groups g))
  ),
  tagged as (
    select
      r.*,
      case
        when r.kind = 'earn_homework' and r.group_id is not null
        then 'g:' || r.group_id::text
        else 'l:' || r.ledger_id::text
      end as bucket_id
    from rows r
  ),
  show_buckets as (
    select distinct
      case
        when r.kind = 'earn_homework' and r.group_id is not null
        then 'g:' || r.group_id::text
        else 'l:' || r.ledger_id::text
      end as bucket_id
    from recent r
  ),
  agg as (
    select
      t.bucket_id as id,
      max(t.created_at) as created_at,
      max(t.kind) as kind,
      sum(t.delta)::integer as delta,
      max(t.group_title) as title,
      case
        when max(t.kind) <> 'earn_homework' then max(t.item_detail)
        when count(*) = 1 then max(t.item_detail)
        else
          '하위과제 ' || count(*)::text || '개'
          || case
            when coalesce(sum(t.problem_count), 0) > 0
            then ' · 문항 ' || sum(t.problem_count)::integer::text || '개'
            else ''
          end
      end as detail,
      max(t.group_id) as group_id,
      case
        when max(t.kind) = 'earn_homework' then
          coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id', t.ledger_id::text,
                'created_at', t.created_at,
                'delta', t.delta,
                'title', t.item_title,
                'detail', t.item_detail
              )
              order by t.item_order_index nulls last, t.created_at, t.ledger_id
            ),
            '[]'::jsonb
          )
        else '[]'::jsonb
      end as children
    from tagged t
    where t.bucket_id in (select s.bucket_id from show_buckets s)
    group by t.bucket_id
  )
  select
    a.id,
    a.created_at,
    a.kind,
    a.delta,
    a.title,
    a.detail,
    a.group_id,
    a.children
  from agg a
  order by a.created_at desc, a.id desc
  limit v_limit;
end;
$$;

revoke all on function public.student_list_recent_points_v1(integer) from public;
grant execute on function public.student_list_recent_points_v1(integer)
  to authenticated;

comment on function public.student_list_recent_points_v1(integer) is
  '학생앱 포인트 내역. 과제는 그룹 단위로 합산하고 children 에 하위과제를 넣는다.';
