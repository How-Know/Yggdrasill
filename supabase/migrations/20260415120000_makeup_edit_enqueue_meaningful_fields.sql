-- 보강 수정 알림: 의미 있는 변경 판정에 session_overrides 나머지 컬럼 포함
-- (set_id / occurrence_id 등만 바뀐 경우에도 큐가 갱신되도록)

create or replace function public.enqueue_makeup_notification_on_create()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_consented boolean := false;
  v_q_status text;
begin
  if new.reason is distinct from 'makeup' then
    return new;
  end if;
  if new.status is distinct from 'planned' then
    return new;
  end if;
  if new.override_type is null or new.override_type not in ('replace', 'add') then
    return new;
  end if;
  if new.replacement_class_datetime is null then
    return new;
  end if;

  if (new.replacement_class_datetime at time zone 'Asia/Seoul')::date
      < (now() at time zone 'Asia/Seoul')::date then
    return new;
  end if;

  select coalesce(sbi.notification_consent, false)
    into v_consented
  from public.student_basic_info sbi
  where sbi.student_id = new.student_id
  limit 1;

  if not coalesce(v_consented, false) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    insert into public.makeup_notification_queue (
      session_override_id,
      academy_id,
      student_id,
      event_type,
      status
    ) values (
      new.id,
      new.academy_id,
      new.student_id,
      'scheduled_created',
      'pending'
    )
    on conflict (session_override_id, event_type) do nothing;

    return new;
  end if;

  -- UPDATE: 실질 필드(앱 updateSessionOverride 가 보내는 컬럼) 중 하나라도 바뀌면 반응
  if new.replacement_class_datetime is not distinct from old.replacement_class_datetime
     and new.original_class_datetime is not distinct from old.original_class_datetime
     and new.change_reason is not distinct from old.change_reason
     and new.override_type is not distinct from old.override_type
     and new.duration_minutes is not distinct from old.duration_minutes
     and new.reason is not distinct from old.reason
     and new.status is not distinct from old.status
     and new.set_id is not distinct from old.set_id
     and new.occurrence_id is not distinct from old.occurrence_id
     and new.session_type_id is not distinct from old.session_type_id
     and new.original_attendance_id is not distinct from old.original_attendance_id
     and new.replacement_attendance_id is not distinct from old.replacement_attendance_id then
    return new;
  end if;

  select q.status
    into v_q_status
  from public.makeup_notification_queue q
  where q.session_override_id = new.id
    and q.event_type = 'scheduled_created'
  limit 1;

  if found and v_q_status in ('pending', 'processing', 'error') then
    update public.makeup_notification_queue q
    set
      status = 'pending',
      attempts = 0,
      last_error = null
    where q.session_override_id = new.id
      and q.event_type = 'scheduled_created';
    return new;
  end if;

  if found and v_q_status in ('sent', 'skipped') then
    insert into public.makeup_notification_queue (
      session_override_id,
      academy_id,
      student_id,
      event_type,
      status
    ) values (
      new.id,
      new.academy_id,
      new.student_id,
      'scheduled_updated',
      'pending'
    )
    on conflict (session_override_id, event_type) do update set
      status = 'pending',
      attempts = 0,
      last_error = null;
    return new;
  end if;

  insert into public.makeup_notification_queue (
    session_override_id,
    academy_id,
    student_id,
    event_type,
    status
  ) values (
    new.id,
    new.academy_id,
    new.student_id,
    'scheduled_created',
    'pending'
  )
  on conflict (session_override_id, event_type) do nothing;

  return new;
end;
$$;
