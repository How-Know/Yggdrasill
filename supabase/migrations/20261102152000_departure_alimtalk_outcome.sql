-- 학습앱이 하원 알림톡 결과만 본다. 전화번호와 발송 본문은 돌려주지 않는다.
-- 워커 기본 재시도는 5회다. 그 전에 error 여도 아직 다시 보낸다.

create or replace function public.staff_departure_alimtalk_outcome_v1(
  p_attendance_id uuid
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_attempts integer;
begin
  if p_attendance_id is null then
    raise exception 'ATTENDANCE_ID_REQUIRED';
  end if;

  select q.status, q.attempts
    into v_status, v_attempts
    from public.attendance_notification_queue q
   where q.attendance_id = p_attendance_id
     and q.event_type = 'departure'
     and exists (
       select 1
         from public.memberships m
        where m.academy_id = q.academy_id
          and m.user_id = auth.uid()
     );

  if not found then
    if exists (
      select 1
        from public.attendance_records ar
        join public.memberships m
          on m.academy_id = ar.academy_id
         and m.user_id = auth.uid()
       where ar.id = p_attendance_id
    ) then
      return 'pending';
    end if;
    raise exception 'FORBIDDEN';
  end if;

  if v_status = 'sent' then
    return 'sent';
  end if;
  if v_status = 'skipped' then
    return 'failed';
  end if;
  if v_status = 'error' and coalesce(v_attempts, 0) >= 5 then
    return 'failed';
  end if;
  return 'pending';
end;
$$;

revoke all on function public.staff_departure_alimtalk_outcome_v1(uuid)
  from public, anon;
grant execute on function public.staff_departure_alimtalk_outcome_v1(uuid)
  to authenticated;
