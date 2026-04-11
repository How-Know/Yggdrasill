-- 보강 알림톡: session_overrides UPDATE 시에도 큐 적재
-- - 아직 발송 전(pending/error 등)이면 scheduled_created 행만 pending 으로 리셋(중복 발송 방지)
-- - 이미 sent/skipped 면 scheduled_updated 행으로 재알림(워커는 해당 타입은 already_sent 스킵 안 함)

alter table public.makeup_notification_queue
  drop constraint if exists makeup_notification_queue_event_type_check;

alter table public.makeup_notification_queue
  add constraint makeup_notification_queue_event_type_check
  check (event_type in ('scheduled_created', 'scheduled_updated'));

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

  -- UPDATE: 의미 있는 필드만 반응
  if new.replacement_class_datetime is not distinct from old.replacement_class_datetime
     and new.original_class_datetime is not distinct from old.original_class_datetime
     and new.change_reason is not distinct from old.change_reason
     and new.override_type is not distinct from old.override_type
     and new.duration_minutes is not distinct from old.duration_minutes
     and new.reason is not distinct from old.reason
     and new.status is not distinct from old.status then
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

  -- scheduled_created 행이 없으면(예: 당시 동의 없음 등) 신규와 동일하게 적재
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

drop trigger if exists trg_enqueue_makeup_notification on public.session_overrides;
create trigger trg_enqueue_makeup_notification
  after insert or update on public.session_overrides
  for each row execute function public.enqueue_makeup_notification_on_create();
