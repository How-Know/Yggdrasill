-- Acknowledging a confirmed group has one authoritative server behavior:
-- pending_complete=true items complete immediately; the rest cycle to waiting.
-- Every client (teacher, M5, student app) already calls this shared RPC.

alter function public.homework_group_bulk_transition(uuid, uuid, smallint)
  rename to homework_group_bulk_transition_cycle;

create or replace function public.homework_group_bulk_transition(
  p_group_id uuid,
  p_academy_id uuid,
  p_from_phase smallint default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_id uuid;
  v_completed integer := 0;
  v_transitioned integer := 0;
begin
  if p_from_phase is null or p_from_phase = 4 then
    for v_item_id in
      select h.id
        from public.homework_items h
        join public.homework_group_items gi
          on gi.homework_item_id = h.id
         and gi.group_id = p_group_id
         and gi.academy_id = p_academy_id
       where h.academy_id = p_academy_id
         and h.phase = 4
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and coalesce(h.pending_complete, false)
       for update of h
    loop
      perform public.homework_complete(v_item_id, p_academy_id);

      -- Completed rows must not retain a runnable phase or completion intent.
      update public.homework_items h
         set phase = 0,
             pending_complete = false,
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
       where h.id = v_item_id
         and h.academy_id = p_academy_id;

      v_completed := v_completed + 1;
    end loop;
  end if;

  -- Non-completing items keep the existing cycle behavior (4 -> 1).
  v_transitioned := coalesce(
    public.homework_group_bulk_transition_cycle(
      p_group_id,
      p_academy_id,
      p_from_phase
    ),
    0
  );

  return v_completed + v_transitioned;
end;
$$;

revoke all on function public.homework_group_bulk_transition(uuid, uuid, smallint)
  from public;
grant execute on function public.homework_group_bulk_transition(uuid, uuid, smallint)
  to anon, authenticated;
