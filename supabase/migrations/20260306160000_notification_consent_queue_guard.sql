-- 20260306: Queue guard for student notification consent

-- 1) attendance_records trigger should enqueue only consented students
create or replace function public.enqueue_attendance_notification()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_consented boolean := false;
begin
  select coalesce(sbi.notification_consent, false)
    into v_consented
    from public.student_basic_info sbi
   where sbi.student_id = new.student_id
   limit 1;

  if not coalesce(v_consented, false) then
    return new;
  end if;

  if (TG_OP = 'INSERT') then
    if (new.arrival_time is not null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'arrival', 'pending'
      ) on conflict do nothing;
    end if;
    if (new.departure_time is not null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'departure', 'pending'
      ) on conflict do nothing;
    end if;
  else
    if (new.arrival_time is not null and old.arrival_time is null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'arrival', 'pending'
      ) on conflict do nothing;
    end if;
    if (new.departure_time is not null and old.departure_time is null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'departure', 'pending'
      ) on conflict do nothing;
    end if;
  end if;
  return new;
end; $$;

-- 2) late enqueue RPC should also include consent check
create or replace function public.enqueue_due_late_notifications(
  p_limit integer default 500
) returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_limit integer := greatest(coalesce(p_limit, 500), 1);
  v_inserted integer := 0;
begin
  with due as (
    select
      ar.id as attendance_id,
      ar.academy_id,
      ar.student_id
    from public.attendance_records ar
    join public.student_basic_info sbi
      on sbi.student_id = ar.student_id
    left join public.student_payment_info spi
      on spi.student_id = ar.student_id
    where ar.class_date_time is not null
      and ar.arrival_time is null
      and ar.departure_time is null
      and coalesce(sbi.notification_consent, false) = true
      and coalesce(spi.lateness_notification, true) = true
      and now() >= ar.class_date_time
        + make_interval(mins => greatest(coalesce(spi.lateness_threshold, 10), 0))
      and coalesce(
        ar.date,
        (ar.class_date_time at time zone 'Asia/Seoul')::date
      ) = (now() at time zone 'Asia/Seoul')::date
      and not exists (
        select 1
        from public.attendance_notification_queue q
        where q.attendance_id = ar.id
          and q.event_type = 'late'
      )
    order by ar.class_date_time asc
    limit v_limit
  )
  insert into public.attendance_notification_queue (
    attendance_id,
    academy_id,
    student_id,
    event_type,
    status
  )
  select
    d.attendance_id,
    d.academy_id,
    d.student_id,
    'late',
    'pending'
  from due d
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

grant execute on function public.enqueue_due_late_notifications(integer) to anon, authenticated;
