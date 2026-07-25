-- student_pause_all이 homework_items만 멈추고 group_runtime.run_start는
-- 그대로 남겨, 학생앱에서 일시정지 후에도 수행중으로 남는 문제를 고친다.

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

  -- 그룹 런타임도 함께 정지 (phase는 수행 중 유지, 타이머만 멈춤).
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
         updated_at = v_now,
         version = coalesce(r.version, 1) + 1
   where r.academy_id = v_academy
     and r.student_id = v_student
     and (r.phase = 2 or r.run_start is not null);
end;
$$;

revoke all on function public.student_pause_all() from public;
grant execute on function public.student_pause_all() to authenticated;
