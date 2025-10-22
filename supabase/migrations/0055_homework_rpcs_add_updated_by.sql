-- Add p_updated_by parameter to homework RPCs for M5 device tracking

-- homework_start: accept updated_by
create or replace function public.homework_start(
  p_item_id uuid, 
  p_student_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  perform 1 from public.homework_items h
    join public.students s on s.id = h.student_id
  where h.id = p_item_id and h.academy_id = p_academy_id and h.student_id = p_student_id;
  if not found then
    return;
  end if;
  -- pause others
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + extract(epoch from (now() - run_start))::bigint * 1000,
        run_start = null,
        updated_at = now(),
        version = coalesce(version,1) + 1,
        phase = 1
  where student_id = p_student_id and academy_id = p_academy_id and run_start is not null and completed_at is null;
  -- start target
  update public.homework_items
    set run_start = now(),
        first_started_at = coalesce(first_started_at, now()),
        updated_at = now(),
        updated_by = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
        version = coalesce(version,1) + 1,
        phase = 2
  where id = p_item_id and academy_id = p_academy_id;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 2::smallint, null::text);
end$$;
revoke all on function public.homework_start(uuid,uuid,uuid,text) from public;
grant execute on function public.homework_start(uuid,uuid,uuid,text) to anon, authenticated;

-- homework_pause: accept updated_by
create or replace function public.homework_pause(
  p_item_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + extract(epoch from (now() - run_start))::bigint * 1000,
        run_start = null,
        updated_at = now(),
        updated_by = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
        version = coalesce(version,1) + 1,
        phase = 1
  where id = p_item_id and academy_id = p_academy_id and run_start is not null;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);
end$$;
revoke all on function public.homework_pause(uuid,uuid,text) from public;
grant execute on function public.homework_pause(uuid,uuid,text) to anon, authenticated;

-- homework_submit: accept updated_by
create or replace function public.homework_submit(
  p_item_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (now() - run_start))::bigint * 1000
                                 else 0 end,
         run_start    = null,
         phase        = 3,
         submitted_at = now(),
         updated_at   = now(),
         updated_by   = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version      = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 3::smallint, null::text);
end$$;
revoke all on function public.homework_submit(uuid,uuid,text) from public;
grant execute on function public.homework_submit(uuid,uuid,text) to anon, authenticated;

-- homework_confirm: accept updated_by
create or replace function public.homework_confirm(
  p_item_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (now() - run_start))::bigint * 1000
                                 else 0 end,
         run_start     = null,
         phase         = 4,
         confirmed_at  = now(),
         updated_at    = now(),
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 4::smallint, null::text);
end$$;
revoke all on function public.homework_confirm(uuid,uuid,text) from public;
grant execute on function public.homework_confirm(uuid,uuid,text) to anon, authenticated;

-- homework_wait: accept updated_by
create or replace function public.homework_wait(
  p_item_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (now() - run_start))::bigint * 1000
                                 else 0 end,
         run_start     = null,
         phase         = 1,
         waiting_at    = now(),
         updated_at    = now(),
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);
end$$;
revoke all on function public.homework_wait(uuid,uuid,text) from public;
grant execute on function public.homework_wait(uuid,uuid,text) to anon, authenticated;

-- homework_pause_all: accept updated_by
create or replace function public.homework_pause_all(
  p_student_id uuid, 
  p_academy_id uuid,
  p_updated_by text default null
)
returns void
language plpgsql
security definer
set search_path = public as $$
declare
  v_ids uuid[];
begin
  -- collect IDs
  select array_agg(h.id)
    into v_ids
    from public.homework_items h
   where h.academy_id = p_academy_id
     and h.student_id = p_student_id
     and h.run_start is not null
     and h.completed_at is null;

  -- pause them
  update public.homework_items h
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + extract(epoch from (now() - run_start))::bigint * 1000,
         run_start   = null,
         updated_at  = now(),
         updated_by  = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version     = coalesce(version,1) + 1,
         phase       = 1
   where h.academy_id = p_academy_id
     and h.student_id = p_student_id
     and h.run_start is not null
     and h.completed_at is null;
end$$;
revoke all on function public.homework_pause_all(uuid,uuid,text) from public;
grant execute on function public.homework_pause_all(uuid,uuid,text) to anon, authenticated;



