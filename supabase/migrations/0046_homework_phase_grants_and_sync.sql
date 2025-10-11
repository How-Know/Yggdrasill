-- Grants for new RPCs and events table, and phase sync on start/pause

-- 1) Grants for RPCs
revoke all on function public.homework_submit(uuid,uuid) from public;
revoke all on function public.homework_confirm(uuid,uuid) from public;
revoke all on function public.homework_wait(uuid,uuid) from public;
grant execute on function public.homework_submit(uuid,uuid) to anon, authenticated;
grant execute on function public.homework_confirm(uuid,uuid) to anon, authenticated;
grant execute on function public.homework_wait(uuid,uuid) to anon, authenticated;

-- 2) RLS for events (read allowed within same academy)
alter table if exists public.homework_item_phase_events enable row level security;
drop policy if exists homework_item_phase_events_all on public.homework_item_phase_events;
create policy homework_item_phase_events_all on public.homework_item_phase_events for all
using (exists (select 1 from public.memberships s where s.academy_id = homework_item_phase_events.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = homework_item_phase_events.academy_id and s.user_id = auth.uid()));

-- 3) Phase sync in start/pause
-- On start: set phase=2 (수행)
create or replace function public.homework_start(p_item_id uuid, p_student_id uuid, p_academy_id uuid)
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
        phase = 1 -- 대기
  where student_id = p_student_id and academy_id = p_academy_id and run_start is not null and completed_at is null;
  -- start target
  update public.homework_items
    set run_start = now(),
        first_started_at = coalesce(first_started_at, now()),
        updated_at = now(),
        version = coalesce(version,1) + 1,
        phase = 2 -- 수행
  where id = p_item_id and academy_id = p_academy_id;
  -- optional: event log for start
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 2::smallint, null::text);
end$$;
revoke all on function public.homework_start(uuid,uuid,uuid) from public;
grant execute on function public.homework_start(uuid,uuid,uuid) to anon, authenticated;

-- On pause: set phase=1 (대기)
create or replace function public.homework_pause(p_item_id uuid, p_academy_id uuid)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + extract(epoch from (now() - run_start))::bigint * 1000,
        run_start = null,
        updated_at = now(),
        version = coalesce(version,1) + 1,
        phase = 1 -- 대기
  where id = p_item_id and academy_id = p_academy_id and run_start is not null;
  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);
end$$;
revoke all on function public.homework_pause(uuid,uuid) from public;
grant execute on function public.homework_pause(uuid,uuid) to anon, authenticated;


