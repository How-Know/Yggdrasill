-- 희망 목표: 등급 코드뿐 아니라 상위 % 일의자리까지 저장.

alter table public.student_level_states
  add column if not exists desired_top_percent smallint;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'chk_student_level_states_desired_top_percent'
  ) then
    alter table public.student_level_states
      add constraint chk_student_level_states_desired_top_percent
      check (
        desired_top_percent is null
        or (desired_top_percent between 1 and 100)
      );
  end if;
end
$$;

comment on column public.student_level_states.desired_top_percent is
  '학생 희망 목표 상위 퍼센트(1~100). desired_level_code의 정확한 값.';

-- 기존 희망 등급만 있는 행은 해당 등급 상한 %로 채운다.
update public.student_level_states s
set desired_top_percent = sc.upper_percent::smallint
from public.student_level_scales sc
where s.desired_top_percent is null
  and s.desired_level_code is not null
  and sc.academy_id = s.academy_id
  and sc.level_code = s.desired_level_code;

drop function if exists public.student_get_desired_level_v1();
drop function if exists public.student_set_desired_level_v1(smallint);

create or replace function public.student_get_desired_level_v1()
returns table (
  desired_level_code smallint,
  desired_top_percent smallint,
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
  v_top smallint;
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

  select s.desired_level_code, s.desired_top_percent
    into v_desired, v_top
  from public.student_level_states s
  where s.academy_id = v_academy
    and s.student_id = v_student;

  if v_top is null and v_desired is not null then
    select sc.upper_percent::smallint
      into v_top
    from public.student_level_scales sc
    where sc.academy_id = v_academy
      and sc.level_code = v_desired;
  end if;

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
    v_top,
    coalesce(v_top::numeric, sc.upper_percent),
    sc.display_name,
    v_options
  from (select 1) _
  left join public.student_level_scales sc
    on sc.academy_id = v_academy
   and sc.level_code = v_desired;
end;
$$;

revoke all on function public.student_get_desired_level_v1() from public;
grant execute on function public.student_get_desired_level_v1() to authenticated;

create or replace function public.student_set_desired_level_v1(
  p_top_percent smallint
)
returns table (
  desired_level_code smallint,
  desired_top_percent smallint,
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
  v_top smallint;
  v_level smallint;
  v_name text;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_top := p_top_percent;
  if v_top is not null and (v_top < 1 or v_top > 100) then
    raise exception 'invalid desired top percent';
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

  if v_top is null then
    v_level := null;
    v_name := null;
  else
    select sc.level_code, sc.display_name
      into v_level, v_name
    from public.student_level_scales sc
    where sc.academy_id = v_academy
      and sc.upper_percent >= v_top
    order by sc.level_code
    limit 1;

    if v_level is null then
      select sc.level_code, sc.display_name
        into v_level, v_name
      from public.student_level_scales sc
      where sc.academy_id = v_academy
      order by sc.level_code desc
      limit 1;
    end if;
  end if;

  insert into public.student_level_states as s (
    academy_id,
    student_id,
    desired_level_code,
    desired_top_percent
  )
  values (v_academy, v_student, v_level, v_top)
  on conflict (academy_id, student_id) do update
  set desired_level_code = excluded.desired_level_code,
      desired_top_percent = excluded.desired_top_percent,
      updated_at = now()
  where s.desired_level_code is distinct from excluded.desired_level_code
     or s.desired_top_percent is distinct from excluded.desired_top_percent;

  return query
  select
    v_level,
    v_top,
    v_top::numeric,
    v_name;
end;
$$;

revoke all on function public.student_set_desired_level_v1(smallint) from public;
grant execute on function public.student_set_desired_level_v1(smallint) to authenticated;
