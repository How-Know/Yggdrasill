-- student_pause_all: updated_by는 uuid 컬럼이라 'student-app:' 접두사를
-- 붙이면 p_updated_by::uuid 캐스팅이 실패해 일시정지가 통째로 롤백됐다.

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
  v_updated_by text := auth.uid()::text;
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
    v_updated_by
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
