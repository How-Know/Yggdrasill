-- Refresh m5_get_students_today_basic to include school/grade.
-- Note: this is a reapply migration; editing old files won't re-run.

drop function if exists public.m5_get_students_today_basic(uuid);

create or replace function public.m5_get_students_today_basic(
  p_academy_id uuid
) returns table(
  student_id uuid,
  name text,
  school text,
  grade integer,
  arrival_time timestamptz,
  start_hour integer,
  start_minute integer
) as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  return query
  with hidden as (
    select
      so.student_id,
      date_trunc('minute', so.original_class_datetime at time zone 'Asia/Seoul') as orig_min
    from public.session_overrides so
    where so.academy_id = p_academy_id
      and so.override_type = 'replace'
      and so.reason = 'makeup'
      and so.status <> 'canceled'
      and so.original_class_datetime is not null
      and (so.original_class_datetime at time zone 'Asia/Seoul')::date = today_date
  ),
  base as (
    select
      ar.*,
      coalesce(nullif(ar.set_id, ''), stb.set_id) as eff_set_id
    from public.attendance_records ar
    left join lateral (
      select b.set_id
      from public.student_time_blocks b
      where b.academy_id = p_academy_id
        and b.student_id = ar.student_id
        and b.set_id is not null and b.set_id <> ''
        and b.day_index = case
          when extract(dow from (ar.class_date_time at time zone 'Asia/Seoul'))::int = 0 then 6
          else extract(dow from (ar.class_date_time at time zone 'Asia/Seoul'))::int - 1
        end
        and b.start_hour = extract(hour from (ar.class_date_time at time zone 'Asia/Seoul'))::int
        and b.start_minute = extract(minute from (ar.class_date_time at time zone 'Asia/Seoul'))::int
        and b.start_date <= (ar.class_date_time at time zone 'Asia/Seoul')::date
        and (b.end_date is null or b.end_date >= (ar.class_date_time at time zone 'Asia/Seoul')::date)
      order by b.start_date desc nulls last, b.created_at desc
      limit 1
    ) stb on true
    where ar.academy_id = p_academy_id
      and ar.date = today_date
      and ar.class_date_time is not null
      and not (
        coalesce(ar.is_planned, false) = true
        and coalesce(ar.is_present, false) = false
        and ar.arrival_time is null
        and ar.departure_time is null
        and exists (
          select 1 from hidden h
          where h.student_id = ar.student_id
            and h.orig_min = date_trunc('minute', ar.class_date_time at time zone 'Asia/Seoul')
        )
      )
  ),
  ranked as (
    select
      b.*,
      row_number() over (
        partition by b.eff_set_id
        order by
          case when (b.arrival_time is not null or b.is_present = true) then 1 else 0 end desc,
          case when coalesce(b.is_planned, false) then 1 else 0 end asc,
          b.class_date_time asc
      ) as rn
    from base b
    where b.eff_set_id is not null and b.eff_set_id <> ''
  ),
  selected as (
    select r.*
    from ranked r
    where r.rn = 1
      and r.arrival_time is null
      and (r.is_present is null or r.is_present = false)
      and r.departure_time is null
  )
  select
    s.student_id,
    st.name,
    st.school,
    st.grade,
    s.arrival_time,
    extract(hour from (s.class_date_time at time zone 'Asia/Seoul'))::int as start_hour,
    extract(minute from (s.class_date_time at time zone 'Asia/Seoul'))::int as start_minute
  from selected s
  join public.students st on st.id = s.student_id
  order by s.class_date_time asc, st.name asc;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_get_students_today_basic(uuid) to anon, authenticated;
