-- 일시정지 시 group_runtime을 phase=1(대기)로 내려 학습앱/M5와
-- "수행중" 표시를 일치시킨다. (phase=2 + run_start null 이면 학습앱이 계속 수행중으로 본다)

create or replace function public.student_pause_all()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_now timestamptz := now();
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  perform public.homework_pause_all(
    v_student,
    v_academy,
    'student-app:' || auth.uid()::text
  );

  update public.homework_group_runtime r
     set accumulated_ms = coalesce(r.accumulated_ms, 0)
           + case
               when r.run_start is not null
                 then greatest(
                   0,
                   floor(extract(epoch from (v_now - r.run_start)) * 1000)::bigint
                 )
               else 0
             end,
         run_start = null,
         phase = 1,
         updated_at = v_now,
         version = coalesce(r.version, 1) + 1
   where r.academy_id = v_academy
     and r.student_id = v_student
     and (r.phase = 2 or r.run_start is not null);

  -- 자식 아이템 phase도 대기로 맞춤 (homework_pause_all이 run_start만 비운 경우 대비).
  update public.homework_items hi
     set phase = 1,
         run_start = null,
         updated_at = v_now,
         version = coalesce(hi.version, 1) + 1
   where hi.academy_id = v_academy
     and hi.student_id = v_student
     and hi.completed_at is null
     and (hi.phase = 2 or hi.run_start is not null);
end;
$$;

revoke all on function public.student_pause_all() from public;
grant execute on function public.student_pause_all() to authenticated;
