-- 완료 표시(pending_complete)가 있는 확인(phase 4) 과제는 하원 때
-- 대기로 내리지 않는다. 다시 등원해도 하원 전과 같은 확인 상태로 남긴다.
-- 확인만 된 과제와 수행·제출 과제는 기존처럼 대기로 돌아간다.

create or replace function public.homework_wait(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_group_id uuid;
begin
  if exists (
    select 1
      from public.homework_items h
     where h.id = p_item_id
       and h.academy_id = p_academy_id
       and h.completed_at is null
       and coalesce(h.phase, 1) = 4
       and coalesce(h.pending_complete, false)
  ) then
    return;
  end if;

  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (v_now - run_start))::bigint * 1000
                                 else 0 end,
         run_start     = null,
         phase         = 1,
         waiting_at    = v_now,
         updated_at    = v_now,
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);

  for v_group_id in
    select distinct gi.group_id
      from public.homework_group_items gi
     where gi.academy_id = p_academy_id
       and gi.homework_item_id = p_item_id
  loop
    perform public.m5_group_runtime_sync_from_children(
      p_academy_id,
      v_group_id,
      v_now
    );
  end loop;
end;
$$;

create or replace function public._homework_reset_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cut timestamptz;
  v_item record;
begin
  if new.departure_time is null
     or old.departure_time is not null then
    return new;
  end if;

  v_cut := least(new.departure_time, now());

  for v_item in
    select i.item_id, h.run_start
    from public.homework_study_intervals i
    join public.homework_items h on h.id = i.item_id
    where i.academy_id = new.academy_id
      and i.student_id = new.student_id
      and i.ended_at is null
  loop
    perform public._homework_close_interval(
      v_item.item_id,
      greatest(v_cut, v_item.run_start),
      'departure'
    );
  end loop;

  update public.homework_items h
  set accumulated_ms = coalesce(h.accumulated_ms, 0)
        + greatest(
            0,
            floor(extract(epoch from (greatest(v_cut, h.run_start) - h.run_start)) * 1000)::bigint
          ),
      run_start = null,
      updated_at = now(),
      version = coalesce(h.version, 1) + 1
  where h.academy_id = new.academy_id
    and h.student_id = new.student_id
    and h.run_start is not null
    and h.completed_at is null;

  with reset as (
    update public.homework_items h
    set phase = 1,
        run_start = null,
        waiting_at = now(),
        updated_at = now(),
        version = coalesce(h.version, 1) + 1
    where h.academy_id = new.academy_id
      and h.student_id = new.student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) not in (0, 1)
      and not (
        coalesce(h.phase, 1) = 4
        and coalesce(h.pending_complete, false)
      )
    returning h.id
  )
  insert into public.homework_item_phase_events (
    academy_id, item_id, phase, actor_user_id, note
  )
  select new.academy_id, r.id, 1::smallint, auth.uid(), 'departure_reset'
  from reset r;

  update public.homework_group_runtime r
  set accumulated_ms = coalesce(r.accumulated_ms, 0)
        + case
            when r.run_start is not null then greatest(
              0,
              floor(extract(epoch from (greatest(v_cut, r.run_start) - r.run_start)) * 1000)::bigint
            )
            else 0
          end,
      run_start = null,
      phase = case
        when exists (
          select 1
            from public.homework_group_items gi
            join public.homework_items h
              on h.id = gi.homework_item_id
             and h.academy_id = gi.academy_id
           where gi.group_id = r.group_id
             and gi.academy_id = r.academy_id
             and h.completed_at is null
             and coalesce(h.status, 0) <> 1
             and coalesce(h.phase, 1) = 4
             and coalesce(h.pending_complete, false)
        ) then 4
        else 1
      end,
      updated_at = now(),
      version = coalesce(r.version, 1) + 1
  where r.academy_id = new.academy_id
    and r.student_id = new.student_id
    and (r.phase <> 1 or r.run_start is not null);

  begin
    perform public._homework_finalize_session_plan_departure(new.id);
  exception
    when others then
      raise warning 'homework finalize on departure failed attendance=%: %',
        new.id, sqlerrm;
  end;

  return new;
end;
$$;
