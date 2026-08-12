-- 학생 수준 스케일을 수능·내신 9등급제로 확장.
-- 기존 6등급(upper 100)은 6등급(77)로 보정하고 7~9등급을 추가한다.

alter table public.student_level_scales
  drop constraint if exists chk_student_level_scales_level_code;
alter table public.student_level_scales
  add constraint chk_student_level_scales_level_code
  check (level_code between 1 and 9);

alter table public.student_level_states
  drop constraint if exists chk_student_level_states_current;
alter table public.student_level_states
  add constraint chk_student_level_states_current
  check (current_level_code is null or current_level_code between 1 and 9);

alter table public.student_level_states
  drop constraint if exists chk_student_level_states_target;
alter table public.student_level_states
  add constraint chk_student_level_states_target
  check (target_level_code is null or target_level_code between 1 and 9);

alter table public.student_level_states
  drop constraint if exists chk_student_level_states_desired;
alter table public.student_level_states
  add constraint chk_student_level_states_desired
  check (desired_level_code is null or desired_level_code between 1 and 9);

-- 누적 상위%: 4 / 11 / 23 / 40 / 60 / 77 / 89 / 96 / 100
update public.student_level_scales
set
  display_name = case level_code
    when 1 then '1등급'
    when 2 then '2등급'
    when 3 then '3등급'
    when 4 then '4등급'
    when 5 then '5등급'
    when 6 then '6등급'
    else display_name
  end,
  upper_percent = case level_code
    when 1 then 4.0
    when 2 then 11.0
    when 3 then 23.0
    when 4 then 40.0
    when 5 then 60.0
    when 6 then 77.0
    else upper_percent
  end,
  updated_at = now()
where level_code between 1 and 6;

insert into public.student_level_scales (
  academy_id, level_code, display_name, upper_percent
)
select
  a.id,
  v.level_code,
  v.display_name,
  v.upper_percent
from public.academies a
cross join (
  values
    (7::smallint, '7등급'::text, 89.0::numeric),
    (8::smallint, '8등급'::text, 96.0::numeric),
    (9::smallint, '9등급'::text, 100.0::numeric)
) as v(level_code, display_name, upper_percent)
on conflict (academy_id, level_code) do update
set
  display_name = excluded.display_name,
  upper_percent = excluded.upper_percent,
  updated_at = now();

create or replace function public.student_get_desired_level_v1()
returns table (
  desired_level_code smallint,
  upper_percent numeric,
  display_name text,
  options jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_desired smallint;
  v_options jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  insert into public.student_level_scales (
    academy_id, level_code, display_name, upper_percent
  )
  select
    v_academy,
    v.level_code,
    v.display_name,
    v.upper_percent
  from (
    values
      (1::smallint, '1등급'::text, 4.0::numeric),
      (2::smallint, '2등급'::text, 11.0::numeric),
      (3::smallint, '3등급'::text, 23.0::numeric),
      (4::smallint, '4등급'::text, 40.0::numeric),
      (5::smallint, '5등급'::text, 60.0::numeric),
      (6::smallint, '6등급'::text, 77.0::numeric),
      (7::smallint, '7등급'::text, 89.0::numeric),
      (8::smallint, '8등급'::text, 96.0::numeric),
      (9::smallint, '9등급'::text, 100.0::numeric)
  ) as v(level_code, display_name, upper_percent)
  on conflict (academy_id, level_code) do update
  set
    display_name = excluded.display_name,
    upper_percent = excluded.upper_percent,
    updated_at = now();

  select s.desired_level_code
    into v_desired
  from public.student_level_states s
  where s.academy_id = v_academy
    and s.student_id = v_student;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'level_code', sc.level_code,
        'display_name', sc.display_name,
        'upper_percent', sc.upper_percent
      )
      order by sc.level_code
    ),
    '[]'::jsonb
  )
  into v_options
  from public.student_level_scales sc
  where sc.academy_id = v_academy;

  return query
  select
    v_desired,
    sc.upper_percent,
    sc.display_name,
    v_options
  from (select 1) _
  left join public.student_level_scales sc
    on sc.academy_id = v_academy
   and sc.level_code = v_desired;
end;
$$;

create or replace function public.student_set_desired_level_v1(
  p_level_code smallint
)
returns table (
  desired_level_code smallint,
  upper_percent numeric,
  display_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_level smallint;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_level := p_level_code;
  if v_level is not null and (v_level < 1 or v_level > 9) then
    raise exception 'invalid desired level';
  end if;

  if v_level is not null then
    insert into public.student_level_scales (
      academy_id, level_code, display_name, upper_percent
    )
    select
      v_academy,
      v.level_code,
      v.display_name,
      v.upper_percent
    from (
      values
        (1::smallint, '1등급'::text, 4.0::numeric),
        (2::smallint, '2등급'::text, 11.0::numeric),
        (3::smallint, '3등급'::text, 23.0::numeric),
        (4::smallint, '4등급'::text, 40.0::numeric),
        (5::smallint, '5등급'::text, 60.0::numeric),
        (6::smallint, '6등급'::text, 77.0::numeric),
        (7::smallint, '7등급'::text, 89.0::numeric),
        (8::smallint, '8등급'::text, 96.0::numeric),
        (9::smallint, '9등급'::text, 100.0::numeric)
    ) as v(level_code, display_name, upper_percent)
    on conflict (academy_id, level_code) do update
    set
      display_name = excluded.display_name,
      upper_percent = excluded.upper_percent,
      updated_at = now();

    if not exists (
      select 1
      from public.student_level_scales sc
      where sc.academy_id = v_academy
        and sc.level_code = v_level
    ) then
      raise exception 'level scale missing';
    end if;
  end if;

  insert into public.student_level_states as s (
    academy_id,
    student_id,
    desired_level_code
  )
  values (v_academy, v_student, v_level)
  on conflict (academy_id, student_id) do update
  set desired_level_code = excluded.desired_level_code,
      updated_at = now()
  where s.desired_level_code is distinct from excluded.desired_level_code;

  return query
  select
    v_level,
    sc.upper_percent,
    sc.display_name
  from (select 1) _
  left join public.student_level_scales sc
    on sc.academy_id = v_academy
   and sc.level_code = v_level;
end;
$$;
