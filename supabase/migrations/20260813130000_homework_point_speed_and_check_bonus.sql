-- 20260813130000: 과제 완료 포인트 시간/검사 보너스 방향 전환 (point_rule_v3)
--
-- v2는 오래 붙잡고 검사를 많이 받을수록 가산했다. 실제로는 권장시간 안에 끝내는
-- 것과 한 번에 통과하는 쪽이 품질이다.
--
-- 기본 10P는 유지. 보너스 상한도 시간 6 / 검사 4 로 같아서 지급 구간은 여전히 10~20.
--
-- 시간 보너스
--   * 레거시(문항 스냅샷 없음): 0. 고정 10 + 검사 보너스만.
--   * 마이그레이션: 권장시간 안쪽에 끝낼수록 선형 가산.
--     elapsed < recommended  →  (1 - elapsed/recommended) × 6
--     elapsed >= recommended →  0
--   * 생성 후 5분 이내 완료, 또는 실측 시간 0: 시간 보너스 0 (비정상 속전)
--
-- 검사 보너스
--   1회(또는 0회) 4P / 2회 8/3P / 3회 4/3P / 4회 이상 0

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
  v_base numeric;
  v_booster numeric;
  v_points integer;
  v_time_reason text;
  v_completed_at timestamptz;
begin
  if new.student_id is null or new.academy_id is null then
    return new;
  end if;

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

  v_base := 10.0 + v_time_bonus + v_check_bonus;
  v_booster := public._booster_for_v1(new.academy_id, new.student_id)::numeric;
  v_points := greatest(round(v_base * v_booster)::integer, 1);

  perform public._point_grant_internal(
    new.academy_id,
    new.student_id,
    v_points,
    'earn_homework',
    'homework_item',
    new.id::text,
    'point_rule_v3',
    jsonb_build_object(
      'accumulated_ms', coalesce(new.accumulated_ms, 0),
      'minutes', round(v_minutes, 2),
      'recommended_minutes', v_recommended,
      'is_migrated', v_is_migrated,
      'too_fast', v_too_fast,
      'time_bonus_reason', v_time_reason,
      'check_count', v_checks,
      'base', round(v_base, 2),
      'time_bonus', round(v_time_bonus, 2),
      'check_bonus', round(v_check_bonus, 2),
      'booster', round(v_booster, 4),
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
