-- 20260306: Late enqueue should follow notification consent only

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
