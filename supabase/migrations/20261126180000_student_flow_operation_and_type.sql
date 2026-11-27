-- 기본 플로우를 개념, 연산, 유형, 사고, 테스트, 서술, 행동으로 맞춘다.
-- 기존 문제 행은 id를 유지한 채 유형으로 바꾼다. 과제·교재 연결은 그 행을 그대로 가리킨다.

update public.student_flows
set name = '유형',
    updated_at = now()
where btrim(name) in ('문제', '선행')
  and not exists (
    select 1
    from public.student_flows other
    where other.academy_id = student_flows.academy_id
      and other.student_id = student_flows.student_id
      and other.id <> student_flows.id
      and btrim(other.name) = '유형'
  );

insert into public.student_flows (
  academy_id,
  student_id,
  name,
  enabled,
  order_index,
  version,
  created_at,
  updated_at
)
select distinct
  sf.academy_id,
  sf.student_id,
  '연산',
  true,
  1,
  1,
  now(),
  now()
from public.student_flows sf
where not exists (
  select 1
  from public.student_flows existing
  where existing.academy_id = sf.academy_id
    and existing.student_id = sf.student_id
    and btrim(existing.name) = '연산'
);

update public.student_flows sf
set enabled = true,
    order_index = defaults.order_index,
    updated_at = now()
from (
  values
    ('개념', 0),
    ('연산', 1),
    ('유형', 2),
    ('사고', 3),
    ('테스트', 4),
    ('서술', 5),
    ('행동', 6)
) as defaults(name, order_index)
where btrim(sf.name) = defaults.name
  and (
    sf.enabled is distinct from true
    or sf.order_index is distinct from defaults.order_index
  );
