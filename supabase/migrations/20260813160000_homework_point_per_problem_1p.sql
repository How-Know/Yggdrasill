-- 20260813160000: 문항당 기본 1P (point_rule_v4 단가 정정)
--
-- 직전 v4는 문항당 10P로 나갔다. 의도한 단가는 1P.
-- 시간/검사 보너스 상한도 10 기준(6/4)의 비율을 유지해 문항당 0.6 / 0.4.

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
  v_points_per_problem numeric := 1.0;
  v_time_cap numeric;
  v_check_cap numeric;
begin
  if new.student_id is null or new.academy_id is null then
    return new;
  end if;

  v_time_cap := v_points_per_problem * 0.6;
  v_check_cap := v_points_per_problem * 0.4;

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
    v_time_bonus := (1.0 - (v_minutes / v_recommended)) * v_time_cap;
    v_time_reason := 'within_recommended';
  end if;

  v_checks := coalesce(new.check_count, 0);
  v_check_bonus := case
    when v_checks <= 1 then v_check_cap
    when v_checks = 2 then v_check_cap * 2.0 / 3.0
    when v_checks = 3 then v_check_cap * 1.0 / 3.0
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
  v_time_total numeric;
  v_check_total numeric;
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
    v_unit := coalesce(nullif(v_basis->>'points_per_problem', '')::numeric, 1);
    v_time := coalesce(nullif(v_basis->>'time_bonus', '')::numeric, 0);
    v_check := coalesce(nullif(v_basis->>'check_bonus', '')::numeric, 0);
    v_checks := coalesce(nullif(v_basis->>'check_count', '')::integer, 0);
    v_reason := coalesce(v_basis->>'time_bonus_reason', '');
    v_booster := nullif(v_basis->>'booster', '')::numeric;

    if v_has_n then
      v_time_total := v_time * v_n;
      v_check_total := v_check * v_n;
      v_parts := array[
        '문항 ' || v_n::text || '개',
        '기본 ' || round(v_n::numeric * v_unit)::integer::text || 'P'
      ];
      if v_time_total >= 0.5 then
        if v_reason = 'within_recommended' then
          v_parts := v_parts || ('빨리 끝내서 +' || round(v_time_total)::integer::text);
        else
          v_parts := v_parts || ('수행 시간 +' || round(v_time_total)::integer::text);
        end if;
      end if;
      if v_check_total >= 0.5 then
        if v_checks <= 1 then
          v_parts := v_parts || ('한 번에 통과해서 +' || round(v_check_total)::integer::text);
        else
          v_parts := v_parts || (
            '검사 ' || v_checks::text || '회로 +' || round(v_check_total)::integer::text
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
