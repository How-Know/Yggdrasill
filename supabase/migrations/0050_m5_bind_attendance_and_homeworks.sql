-- Ensure attendance on bind, and list homeworks for a student

-- 1) Ensure today's attendance exists, otherwise create
create or replace function public.ensure_attendance_today(
  p_academy_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_id uuid;
begin
  select id into v_id
  from public.attendance_records
  where academy_id = p_academy_id
    and student_id = p_student_id
    and date = current_date
  limit 1;

  if v_id is null then
    insert into public.attendance_records(academy_id, student_id, date, is_present, arrival_time)
    values (p_academy_id, p_student_id, current_date, true, now())
    returning id into v_id;
  end if;
  return v_id;
end; $$;

grant execute on function public.ensure_attendance_today(uuid, uuid) to anon, authenticated;

-- 2) Update m5_bind_device to ensure attendance as part of binding
create or replace function public.m5_bind_device(
  p_academy_id uuid,
  p_device_id text,
  p_student_id uuid
) returns void
language plpgsql security definer set search_path=public as $$
begin
  -- close previous bindings for device and student
  update public.m5_device_bindings
  set active=false, unbound_at=now(), updated_at=now()
  where academy_id=p_academy_id and (device_id=p_device_id or student_id=p_student_id) and active=true;

  insert into public.m5_device_bindings(academy_id, device_id, student_id, active, bound_at, updated_at)
  values (p_academy_id, p_device_id, p_student_id, true, now(), now());

  -- ensure attendance for today
  perform public.ensure_attendance_today(p_academy_id, p_student_id);
end; $$;

-- 3) List active homeworks for a student
create or replace function public.m5_list_homeworks(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  item_id uuid,
  title text,
  color bigint,
  phase smallint,
  submitted_at timestamptz,
  confirmed_at timestamptz,
  waiting_at timestamptz
) as $$
begin
  return query
  select h.id as item_id, h.title, h.color::bigint, coalesce(h.phase, 1)::smallint, h.submitted_at, h.confirmed_at, h.waiting_at
  from public.homework_items h
  where h.academy_id = p_academy_id and h.student_id = p_student_id and h.completed_at is null
  order by
    case coalesce(h.phase,1)
      when 2 then 0 -- performing first
      when 1 then 1 -- waiting
      when 4 then 2 -- confirmed
      when 3 then 3 -- submitted
      else 9
    end,
    coalesce(h.waiting_at, h.submitted_at, h.confirmed_at, h.first_started_at, h.created_at);
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homeworks(uuid, uuid) to anon, authenticated;





