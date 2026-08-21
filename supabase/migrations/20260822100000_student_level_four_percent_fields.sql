-- 학생 수준을 네 가지 상위 퍼센트로 분리한다.
-- 낮은 값일수록 높은 수준이다.
-- self_assessed: 학생 자기평가
-- desired: 고3 수능 시점 학생 희망
-- current: 선생님/진단이 추정한 현재 수준
-- predicted_future: 현재 정보로 예상한 고3 수능 시점 수준

alter table public.student_level_states
  add column if not exists self_assessed_top_percent smallint,
  add column if not exists current_top_percent smallint,
  add column if not exists predicted_future_top_percent smallint;

do $$
declare
  v_column text;
  v_constraint text;
begin
  foreach v_column in array array[
    'self_assessed_top_percent',
    'current_top_percent',
    'predicted_future_top_percent'
  ]
  loop
    v_constraint := 'chk_student_level_states_' || v_column;
    if not exists (
      select 1
      from pg_constraint
      where conname = v_constraint
    ) then
      execute format(
        'alter table public.student_level_states add constraint %I check (%I is null or %I between 1 and 100)',
        v_constraint,
        v_column,
        v_column
      );
    end if;
  end loop;
end
$$;

comment on column public.student_level_states.self_assessed_top_percent is
  '학생이 생각하는 현재 수준의 상위 퍼센트(1~100).';
comment on column public.student_level_states.desired_top_percent is
  '학생이 희망하는 고3 수능 시점 상위 퍼센트(1~100).';
comment on column public.student_level_states.current_top_percent is
  '선생님 또는 진단이 추정한 현재 수준의 상위 퍼센트(1~100).';
comment on column public.student_level_states.predicted_future_top_percent is
  '현재 정보로 예상한 고3 수능 시점 상위 퍼센트(1~100).';

-- 기존 등급 코드 값은 등급 상한 퍼센트로 보존한다.
update public.student_level_states s
set current_top_percent = sc.upper_percent::smallint
from public.student_level_scales sc
where s.current_top_percent is null
  and s.current_level_code is not null
  and sc.academy_id = s.academy_id
  and sc.level_code = s.current_level_code;

update public.student_level_states s
set predicted_future_top_percent = sc.upper_percent::smallint
from public.student_level_scales sc
where s.predicted_future_top_percent is null
  and s.target_level_code is not null
  and sc.academy_id = s.academy_id
  and sc.level_code = s.target_level_code;

create or replace function public.student_get_level_profile_v1()
returns table (
  self_assessed_top_percent smallint,
  desired_top_percent smallint,
  desired_level_code smallint,
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
  v_self smallint;
  v_desired smallint;
  v_level smallint;
  v_name text;
  v_options jsonb;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select
    s.self_assessed_top_percent,
    s.desired_top_percent,
    s.desired_level_code
  into v_self, v_desired, v_level
  from public.student_level_states s
  where s.academy_id = v_academy
    and s.student_id = v_student;

  select sc.display_name
    into v_name
  from public.student_level_scales sc
  where sc.academy_id = v_academy
    and sc.level_code = v_level;

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
  select v_self, v_desired, v_level, v_name, v_options;
end;
$$;

revoke all on function public.student_get_level_profile_v1() from public;
grant execute on function public.student_get_level_profile_v1() to authenticated;

create or replace function public.student_set_reported_levels_v1(
  p_self_assessed_top_percent smallint,
  p_desired_top_percent smallint
)
returns table (
  self_assessed_top_percent smallint,
  desired_top_percent smallint,
  desired_level_code smallint,
  display_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_self smallint := p_self_assessed_top_percent;
  v_desired smallint := p_desired_top_percent;
  v_level smallint;
  v_name text;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;
  if v_self is not null and (v_self < 1 or v_self > 100) then
    raise exception 'invalid self assessed top percent';
  end if;
  if v_desired is not null and (v_desired < 1 or v_desired > 100) then
    raise exception 'invalid desired top percent';
  end if;

  if v_desired is not null then
    select sc.level_code, sc.display_name
      into v_level, v_name
    from public.student_level_scales sc
    where sc.academy_id = v_academy
      and sc.upper_percent >= v_desired
    order by sc.level_code
    limit 1;
  end if;

  insert into public.student_level_states as s (
    academy_id,
    student_id,
    self_assessed_top_percent,
    desired_level_code,
    desired_top_percent
  )
  values (v_academy, v_student, v_self, v_level, v_desired)
  on conflict (academy_id, student_id) do update
  set self_assessed_top_percent = excluded.self_assessed_top_percent,
      desired_level_code = excluded.desired_level_code,
      desired_top_percent = excluded.desired_top_percent,
      updated_at = now()
  where s.self_assessed_top_percent is distinct from excluded.self_assessed_top_percent
     or s.desired_level_code is distinct from excluded.desired_level_code
     or s.desired_top_percent is distinct from excluded.desired_top_percent;

  return query
  select v_self, v_desired, v_level, v_name;
end;
$$;

revoke all on function public.student_set_reported_levels_v1(smallint, smallint) from public;
grant execute on function public.student_set_reported_levels_v1(smallint, smallint) to authenticated;
