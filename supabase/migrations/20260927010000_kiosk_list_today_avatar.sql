-- Include the student profile avatar on today's kiosk roster.
create or replace function public.kiosk_list_today(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_items jsonb;
begin
  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.kiosk_devices set last_seen_at = now() where token_hash = p_token_hash;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.class_date_time, q.name), '[]'::jsonb)
  into v_items
  from (
    select ar.id as attendance_id, s.id as student_id, s.name, s.school, s.grade,
           s.avatar_kind, s.avatar_url, s.avatar_emoji, s.avatar_monogram_style,
           ar.set_id, ar.session_type_id, ar.class_date_time, ar.class_end_time,
           ar.arrival_time, (ar.arrival_time is not null) as checked_in,
           coalesce(pin.pin_required, false) as pin_required,
           (pin.pin_hash is not null) as pin_set
    from public.attendance_records ar
    join public.students s on s.id = ar.student_id and s.academy_id = v_academy
    left join public.m5_student_pins pin
      on pin.student_id = s.id and pin.academy_id = v_academy
    where ar.academy_id = v_academy
      and ar.is_planned is true
      and coalesce(ar.date, (ar.class_date_time at time zone 'Asia/Seoul')::date) = v_today
      and ar.departure_time is null
      and not exists (
        select 1
        from public.session_overrides so
        where so.academy_id = v_academy
          and so.student_id = ar.student_id
          and so.override_type = 'replace'
          and so.reason = 'makeup'
          and so.status <> 'canceled'
          and so.original_class_datetime is not null
          and date_trunc(
            'minute',
            so.original_class_datetime at time zone 'Asia/Seoul'
          ) = date_trunc(
            'minute',
            ar.class_date_time at time zone 'Asia/Seoul'
          )
      )
  ) q;
  return jsonb_build_object('ok', true, 'date', v_today, 'students', v_items);
end;
$$;

revoke all on function public.kiosk_list_today(text) from public, anon, authenticated;
grant execute on function public.kiosk_list_today(text) to service_role;
