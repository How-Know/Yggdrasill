-- Student pause periods + charge points (pause-aware billing)
-- - student_pause_periods: track pause/resume ranges
-- - student_charge_points: persist "next due datetime" computed after pause/resume

-- 1) Tables ----------------------------------------------------------------------

create table if not exists public.student_pause_periods (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  paused_from date not null,
  paused_to date,
  note text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_student_pause_periods_academy_student_from
  on public.student_pause_periods(academy_id, student_id, paused_from desc);

alter table public.student_pause_periods enable row level security;
drop policy if exists student_pause_periods_all on public.student_pause_periods;
create policy student_pause_periods_all on public.student_pause_periods for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_pause_periods.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_pause_periods.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_student_pause_periods_audit on public.student_pause_periods;
create trigger trg_student_pause_periods_audit
before insert or update on public.student_pause_periods
for each row execute function public._set_audit_fields();

create table if not exists public.student_charge_points (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  cycle integer not null,
  charge_point_occurrence_id uuid references public.lesson_occurrences(id) on delete set null,
  charge_point_datetime timestamptz,
  next_due_datetime timestamptz,
  computed_at timestamptz not null default now()
);

create unique index if not exists uq_student_charge_points_academy_student_cycle
  on public.student_charge_points(academy_id, student_id, cycle);
create index if not exists idx_student_charge_points_next_due
  on public.student_charge_points(academy_id, next_due_datetime);

alter table public.student_charge_points enable row level security;
drop policy if exists student_charge_points_all on public.student_charge_points;
create policy student_charge_points_all on public.student_charge_points for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_charge_points.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_charge_points.academy_id
      and m.user_id = auth.uid()
  )
);


-- 2) RPCs ------------------------------------------------------------------------

-- Pause start (or update ongoing pause)
create or replace function public.pause_student(
  p_academy_id uuid,
  p_student_id uuid,
  p_from date,
  p_to date default null,
  p_note text default ''
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform set_config('statement_timeout', '60s', true);

  -- if there is an ongoing pause (paused_to is null), update it; else create new
  select id into v_id
  from public.student_pause_periods
  where academy_id = p_academy_id
    and student_id = p_student_id
    and paused_to is null
  order by paused_from desc
  limit 1;

  if v_id is null then
    insert into public.student_pause_periods(academy_id, student_id, paused_from, paused_to, note)
    values (p_academy_id, p_student_id, p_from, p_to, nullif(trim(p_note), ''))
    returning id into v_id;
  else
    update public.student_pause_periods
    set paused_from = p_from,
        paused_to = p_to,
        note = nullif(trim(p_note), '')
    where id = v_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.pause_student(uuid, uuid, date, date, text) to authenticated;


-- Resume (close ongoing pause)
create or replace function public.resume_student(
  p_academy_id uuid,
  p_student_id uuid,
  p_to date
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform set_config('statement_timeout', '60s', true);

  select id into v_id
  from public.student_pause_periods
  where academy_id = p_academy_id
    and student_id = p_student_id
    and paused_to is null
  order by paused_from desc
  limit 1;

  if v_id is null then
    raise exception 'no ongoing pause for student' using errcode = 'P0002';
  end if;

  update public.student_pause_periods
  set paused_to = p_to
  where id = v_id;

  return v_id;
end;
$$;

grant execute on function public.resume_student(uuid, uuid, date) to authenticated;


-- Helper: resolve cycle by due_date (same behavior as client-side resolve)
create or replace function public._resolve_cycle_by_due_date(
  p_academy_id uuid,
  p_student_id uuid,
  p_day date
) returns integer
language sql
stable
set search_path = public
as $$
  select pr.cycle
  from public.payment_records pr
  where pr.academy_id = p_academy_id
    and pr.student_id = p_student_id
    and pr.due_date <= p_day
  order by pr.due_date desc nulls last, pr.cycle desc
  limit 1;
$$;


-- Recompute "next due" based on pause periods and lesson occurrences.
-- This computes for the current cycle (by today's date).
create or replace function public.recompute_charge_points(
  p_academy_id uuid,
  p_student_id uuid
) returns void
language plpgsql
set search_path = public
as $$
declare
  v_cycle integer;
  v_cycle_start date;
  v_cycle_end date;
  v_session_cycle integer := 1;
  v_pause_from date;
  v_pause_to date;
  v_consumed integer := 0;
  v_remaining integer := 0;
  v_charge_occ_id uuid;
  v_charge_dt timestamptz;
  v_next_due timestamptz;
begin
  perform set_config('statement_timeout', '60s', true);

  -- session_cycle from academy_settings
  select coalesce(s.session_cycle, 1) into v_session_cycle
  from public.academy_settings s
  where s.academy_id = p_academy_id
  limit 1;

  v_cycle := public._resolve_cycle_by_due_date(p_academy_id, p_student_id, current_date);
  if v_cycle is null then
    return;
  end if;

  select pr.due_date into v_cycle_start
  from public.payment_records pr
  where pr.academy_id = p_academy_id and pr.student_id = p_student_id and pr.cycle = v_cycle
  limit 1;

  select pr.due_date into v_cycle_end
  from public.payment_records pr
  where pr.academy_id = p_academy_id and pr.student_id = p_student_id and pr.cycle = v_cycle + 1
  limit 1;
  if v_cycle_end is null then
    v_cycle_end := (v_cycle_start + interval '31 days')::date;
  end if;

  -- if there is an ongoing pause, we compute "remaining" as of pause_from
  select p.paused_from, coalesce(p.paused_to, current_date) into v_pause_from, v_pause_to
  from public.student_pause_periods p
  where p.academy_id = p_academy_id
    and p.student_id = p_student_id
    and (p.paused_to is null or p.paused_to >= p.paused_from)
  order by p.paused_to is null desc, p.paused_from desc
  limit 1;
  if v_pause_from is null then
    -- no pause: clear charge point for current cycle (optional). We'll recompute anyway.
    v_pause_from := current_date;
    v_pause_to := current_date;
  end if;

  -- consumed in this cycle before pause_from (non-planned attendance counts as consumed)
  select count(*) into v_consumed
  from public.attendance_records ar
  where ar.academy_id = p_academy_id
    and ar.student_id = p_student_id
    and ar.cycle = v_cycle
    and (ar.is_planned is null or ar.is_planned = false)
    and ar.class_date_time is not null
    and (ar.class_date_time at time zone 'Asia/Seoul')::date < v_pause_from;

  v_remaining := greatest(v_session_cycle - v_consumed, 0);

  -- scan upcoming occurrences across cycles until remaining is consumed (pause days excluded)
  -- We rely on lesson_occurrences being generated for future cycles by client jobs.
  for v_charge_occ_id, v_charge_dt in
    select o.id, o.original_class_datetime
    from public.lesson_occurrences o
    where o.academy_id = p_academy_id
      and o.student_id = p_student_id
      and o.kind = 'regular'
      and o.original_class_datetime is not null
      and o.original_class_datetime >= (v_pause_from::timestamptz)
    order by o.original_class_datetime asc
    limit 2000
  loop
    -- skip if occurrence date is within any pause period (including the current pause)
    if exists (
      select 1 from public.student_pause_periods p
      where p.academy_id = p_academy_id
        and p.student_id = p_student_id
        and p.paused_from <= (v_charge_dt at time zone 'Asia/Seoul')::date
        and (p.paused_to is null or p.paused_to >= (v_charge_dt at time zone 'Asia/Seoul')::date)
    ) then
      continue;
    end if;

    -- if already consumed, skip
    if exists (
      select 1 from public.attendance_records ar
      where ar.academy_id = p_academy_id
        and ar.student_id = p_student_id
        and ar.occurrence_id = v_charge_occ_id
        and (ar.is_planned is null or ar.is_planned = false)
      limit 1
    ) then
      continue;
    end if;

    if v_remaining > 0 then
      v_remaining := v_remaining - 1;
      if v_remaining = 0 then
        -- this occurrence completes the cycle
        -- next_due is the next non-paused occurrence after this
        v_charge_dt := v_charge_dt;
        exit;
      end if;
    end if;
  end loop;

  if v_remaining <> 0 then
    -- Not enough future occurrences in DB to compute
    return;
  end if;

  -- find next_due_datetime
  select o2.original_class_datetime into v_next_due
  from public.lesson_occurrences o2
  where o2.academy_id = p_academy_id
    and o2.student_id = p_student_id
    and o2.kind = 'regular'
    and o2.original_class_datetime > v_charge_dt
    and not exists (
      select 1 from public.student_pause_periods p
      where p.academy_id = p_academy_id
        and p.student_id = p_student_id
        and p.paused_from <= (o2.original_class_datetime at time zone 'Asia/Seoul')::date
        and (p.paused_to is null or p.paused_to >= (o2.original_class_datetime at time zone 'Asia/Seoul')::date)
    )
  order by o2.original_class_datetime asc
  limit 1;

  -- upsert charge point
  insert into public.student_charge_points(
    academy_id, student_id, cycle,
    charge_point_occurrence_id, charge_point_datetime, next_due_datetime, computed_at
  )
  values (
    p_academy_id, p_student_id, v_cycle,
    v_charge_occ_id, v_charge_dt, v_next_due, now()
  )
  on conflict (academy_id, student_id, cycle)
  do update set
    charge_point_occurrence_id = excluded.charge_point_occurrence_id,
    charge_point_datetime = excluded.charge_point_datetime,
    next_due_datetime = excluded.next_due_datetime,
    computed_at = excluded.computed_at;
end;
$$;

grant execute on function public.recompute_charge_points(uuid, uuid) to authenticated;

