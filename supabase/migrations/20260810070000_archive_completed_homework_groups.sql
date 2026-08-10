-- Archive homework groups only after real completion (status = 1).
-- Confirm (phase 4) / pending_complete must NOT archive groups.
--
-- Also cleans historical ghost groups that stayed active after all children
-- completed, then compact remaining active order_index by created_at so the
-- newest live card sits at the bottom.

-- ---------------------------------------------------------------------------
-- 1) Helper: archive a group iff every linked item is completed (status = 1)
-- ---------------------------------------------------------------------------
create or replace function public.homework_archive_group_if_fully_completed(
  p_academy_id uuid,
  p_group_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_incomplete boolean := false;
begin
  if p_academy_id is null or p_group_id is null then
    return false;
  end if;

  -- Incomplete = status is not completed (1). phase/pending_complete alone
  -- must never count as completion.
  select exists (
    select 1
      from public.homework_group_items gi
      join public.homework_items h
        on h.id = gi.homework_item_id
       and h.academy_id = gi.academy_id
     where gi.academy_id = p_academy_id
       and gi.group_id = p_group_id
       and coalesce(h.status, 0) <> 1
  )
  into v_has_incomplete;

  if v_has_incomplete then
    return false;
  end if;

  -- Groups with no links are also archived (orphans).
  update public.homework_groups g
     set status = 'archived',
         updated_at = now(),
         version = coalesce(g.version, 1) + 1
   where g.academy_id = p_academy_id
     and g.id = p_group_id
     and g.status = 'active';

  return found;
end;
$$;

revoke all on function public.homework_archive_group_if_fully_completed(uuid, uuid)
  from public;
grant execute on function public.homework_archive_group_if_fully_completed(uuid, uuid)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) homework_complete: keep level snapshots + archive owning group when done
-- ---------------------------------------------------------------------------
create or replace function public.homework_complete(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
begin
  update public.homework_items hi
     set accumulated_ms = coalesce(hi.accumulated_ms, 0)
                          + case
                              when hi.run_start is not null
                                then extract(epoch from (now() - hi.run_start))::bigint * 1000
                              else 0
                            end,
         run_start = null,
         completed_at = now(),
         status = 1,
         student_level_current_snapshot = (
           select s.current_level_code
             from public.student_level_states s
            where s.student_id = hi.student_id
              and s.academy_id = hi.academy_id
            limit 1
         ),
         student_level_target_snapshot = (
           select s.target_level_code
             from public.student_level_states s
            where s.student_id = hi.student_id
              and s.academy_id = hi.academy_id
            limit 1
         ),
         updated_at = now(),
         version = coalesce(hi.version, 1) + 1
   where hi.id = p_item_id
     and hi.academy_id = p_academy_id;

  if not found then
    return;
  end if;

  select gi.group_id
    into v_group_id
    from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.homework_item_id = p_item_id
   limit 1;

  if v_group_id is not null then
    perform public.homework_archive_group_if_fully_completed(
      p_academy_id,
      v_group_id
    );
  end if;
end;
$$;

revoke all on function public.homework_complete(uuid, uuid) from public;
grant execute on function public.homework_complete(uuid, uuid)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) Reopen completed → waiting: revive archived group at active tail
-- ---------------------------------------------------------------------------
create or replace function public.homework_reopen_completed_to_waiting(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_group_id uuid;
  v_next_order integer;
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms, 0)
                          + case when run_start is not null
                                 then extract(epoch from (now() - run_start))::bigint * 1000
                                 else 0 end,
         run_start     = null,
         status        = 0,
         phase         = 1,
         completed_at  = null,
         submitted_at  = null,
         confirmed_at  = null,
         waiting_at    = now(),
         updated_at    = now(),
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version, 1) + 1
   where id = p_item_id
     and academy_id = p_academy_id
     and (coalesce(status, 0) = 1 or completed_at is not null)
  returning student_id into v_student_id;

  if not found then
    return;
  end if;

  perform public._append_homework_phase_event(
    p_academy_id,
    p_item_id,
    1::smallint,
    'reopen_from_completed'::text
  );

  select gi.group_id
    into v_group_id
    from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.homework_item_id = p_item_id
   limit 1;

  if v_group_id is null then
    return;
  end if;

  select coalesce(max(g.order_index), -1) + 1
    into v_next_order
    from public.homework_groups g
   where g.academy_id = p_academy_id
     and g.student_id = v_student_id
     and g.status = 'active'
     and g.id <> v_group_id;

  update public.homework_groups g
     set status = 'active',
         order_index = v_next_order,
         updated_at = now(),
         version = coalesce(g.version, 1) + 1
   where g.academy_id = p_academy_id
     and g.id = v_group_id
     and g.status = 'archived';
end;
$$;

revoke all on function public.homework_reopen_completed_to_waiting(uuid, uuid, text)
  from public;
grant execute on function public.homework_reopen_completed_to_waiting(uuid, uuid, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) One-shot cleanup: archive ghost active groups (no incomplete children)
-- ---------------------------------------------------------------------------
with ghost_groups as (
  select g.id, g.academy_id
    from public.homework_groups g
   where g.status = 'active'
     and not exists (
       select 1
         from public.homework_group_items gi
         join public.homework_items h
           on h.id = gi.homework_item_id
          and h.academy_id = gi.academy_id
        where gi.academy_id = g.academy_id
          and gi.group_id = g.id
          and coalesce(h.status, 0) <> 1
     )
)
update public.homework_groups g
   set status = 'archived',
       updated_at = now(),
       version = coalesce(g.version, 1) + 1
  from ghost_groups gg
 where g.id = gg.id
   and g.academy_id = gg.academy_id;

-- ---------------------------------------------------------------------------
-- 5) Compact remaining active groups by created_at (oldest top / newest bottom)
-- ---------------------------------------------------------------------------
with ranked as (
  select
    g.id,
    g.academy_id,
    row_number() over (
      partition by g.academy_id, g.student_id
      order by g.created_at asc, g.id asc
    ) - 1 as new_order
  from public.homework_groups g
  where g.status = 'active'
)
update public.homework_groups g
   set order_index = r.new_order,
       updated_at = now(),
       version = coalesce(g.version, 1) + 1
  from ranked r
 where g.id = r.id
   and g.academy_id = r.academy_id
   and g.order_index is distinct from r.new_order;
