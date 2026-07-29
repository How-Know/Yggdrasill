-- 권장시간 초기 α: 준비·이동·채점·검사 시간 10분.
--
-- 계산 스냅샷은 homework_item(하위과제)마다 α를 포함한다. 여러 하위과제가
-- 하나의 그룹 과제로 묶이면 UI 합계에서는 중복 α를 빼고 10분을 한 번만 센다.
-- 간이 시험 및 실제 수행 데이터가 쌓이면 학생별 실측 α로 교체한다.

insert into public.homework_time_defaults (
  academy_id,
  series_key,
  school_level_key,
  category_key,
  seconds_per_unit
)
select
  a.id,
  '',
  '',
  'task_overhead',
  600
from public.academies a
on conflict (academy_id, series_key, school_level_key, category_key)
do update set
  seconds_per_unit = excluded.seconds_per_unit,
  updated_at = now();

-- α 도입 전에 이미 생성된 마이그레이션 교재 과제 스냅샷도 같은 기준으로 맞춘다.
-- 자동값과 확정값에 동일하게 더해 사용자의 수동 보정 차이는 그대로 보존한다.
update public.homework_items
set
  recommended_minutes_auto = recommended_minutes_auto + 10,
  recommended_minutes = case
    when recommended_minutes is null then null
    else recommended_minutes + 10
  end
where book_id is not null
  and btrim(coalesce(grade_label, '')) <> ''
  and recommended_minutes_auto is not null;
