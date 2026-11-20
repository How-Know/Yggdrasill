-- 수력충전 권장시간 기본 단가.
-- 유형(A 유형 문제 / B 단원 마무리)과 과정(중등/고등)을 나누지 않고 문항당 20초.
-- 과제당 준비 시간(task_overhead 10분)은 그대로 둔다.

insert into public.homework_time_defaults (
  academy_id,
  series_key,
  school_level_key,
  category_key,
  seconds_per_unit
)
select
  a.id,
  'suryeok',
  '',
  'item',
  20
from public.academies a
on conflict (academy_id, series_key, school_level_key, category_key)
do update set
  seconds_per_unit = excluded.seconds_per_unit,
  updated_at = now();
