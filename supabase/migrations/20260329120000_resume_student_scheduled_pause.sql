-- resume_student: 예상 등원일까지 지정해 휴원한 학생(paused_to 가 이미 채워진 경우)도 등원 처리 가능하게 함.
-- 기존에는 paused_to is null 인 "진행 중 무기한 휴원"만 닫을 수 있어, pause_student 가 p_to 와 함께
-- insert/update 한 레코드에 대해 등원 시 P0002(no ongoing pause) 가 났음.

create or replace function public.resume_student(
  p_academy_id uuid,
  p_student_id uuid,
  p_to date
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform set_config('statement_timeout', '60s', true);

  -- p_to = 마지막 휴원일(등원일 전날). 클라이언트와 동일.
  -- 1) 무기한 휴원(paused_to is null)
  -- 2) 예상 종료일이 있는 휴원이지만 아직 그 구간을 닫는(앞당기기) 경우: paused_to >= p_to
  select id into v_id
  from public.student_pause_periods
  where academy_id = p_academy_id
    and student_id = p_student_id
    and paused_from <= p_to
    and (paused_to is null or paused_to >= p_to)
  order by paused_from desc
  limit 1;

  if v_id is null then
    raise exception 'no ongoing pause for student' using errcode = 'P0002';
  end if;

  update public.student_pause_periods
  set paused_to = p_to
  where id = v_id;

  return v_id;
end;
$$;
