-- 0052: Fix submit to stop running timer and add pause_all RPC

-- Submit: stop run and accumulate time
create or replace function public.homework_submit(
  p_item_id uuid,
  p_academy_id uuid
) returns void
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
         version      = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 3::smallint, null::text);
end$$;

-- Confirm: be defensive and stop run if any
create or replace function public.homework_confirm(
  p_item_id uuid,
  p_academy_id uuid
) returns void
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
         version       = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 4::smallint, null::text);
end$$;

-- Optional: Wait also stops run
create or replace function public.homework_wait(
  p_item_id uuid,
  p_academy_id uuid
) returns void
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
         version       = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);
end$$;

-- Pause all running homeworks for a student (in current academy)
create or replace function public.homework_pause_all(
  p_student_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
set search_path = public as $$
begin
  -- log events for currently running items
  insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
  select h.academy_id, h.id, 1::smallint, auth.uid(), null
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
         version     = coalesce(version,1) + 1,
         phase       = 1
   where h.academy_id = p_academy_id
     and h.student_id = p_student_id
     and h.run_start is not null
     and h.completed_at is null;
end$$;

-- grants
revoke all on function public.homework_pause_all(uuid,uuid) from public;
grant execute on function public.homework_pause_all(uuid,uuid) to anon, authenticated;



