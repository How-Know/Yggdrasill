-- 학생앱: 희망 등급(desired_level_code) 조회/저장.
-- 현재/예상은 학습앱(강사)이 입력하고, 희망만 학생이 쓴다.
-- RLS는 membership 전용이라 security definer RPC로 본인 행만 다룬다.

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

  -- 학원 스케일이 비어 있으면 기본 등급표를 채운다.
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
      (6::smallint, '6등급'::text, 100.0::numeric)
  ) as v(level_code, display_name, upper_percent)
  on conflict (academy_id, level_code) do nothing;

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

revoke all on function public.student_get_desired_level_v1() from public;
grant execute on function public.student_get_desired_level_v1() to authenticated;

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
  if v_level is not null and (v_level < 1 or v_level > 6) then
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
        (6::smallint, '6등급'::text, 100.0::numeric)
    ) as v(level_code, display_name, upper_percent)
    where v.level_code = v_level
    on conflict (academy_id, level_code) do nothing;

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

revoke all on function public.student_set_desired_level_v1(smallint) from public;
grant execute on function public.student_set_desired_level_v1(smallint) to authenticated;
