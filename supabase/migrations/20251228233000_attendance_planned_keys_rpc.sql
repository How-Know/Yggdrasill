-- RPC: list distinct planned attendance minutes for a range (dedupe-friendly)
-- Purpose: planned generator must not rely on client-side loaded attendance (may be capped by max_rows),
-- and must not explode duplicates when DB already contains planned rows.

create index if not exists idx_attendance_records_academy_class_date_time
  on public.attendance_records(academy_id, class_date_time);

create or replace function public.list_planned_attendance_minutes(
  p_academy_id uuid,
  p_from timestamptz,
  p_to timestamptz
) returns table(
  student_id uuid,
  set_id text,
  class_minute timestamptz
)
language sql
stable
set search_path = public
as $$
  select distinct
    ar.student_id,
    ar.set_id,
    date_trunc('minute', ar.class_date_time) as class_minute
  from public.attendance_records ar
  where ar.academy_id = p_academy_id
    and ar.is_planned = true
    and (ar.is_present is null or ar.is_present = false)
    and ar.arrival_time is null
    and ar.set_id is not null
    and ar.set_id <> ''
    and ar.class_date_time >= p_from
    and ar.class_date_time < p_to;
$$;

grant execute on function public.list_planned_attendance_minutes(uuid, timestamptz, timestamptz) to authenticated;




