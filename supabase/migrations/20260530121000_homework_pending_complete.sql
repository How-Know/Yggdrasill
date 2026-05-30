-- M5: distinguish 확인(confirm, cycles back) from 완료(complete, terminates) while
-- a group still sits in phase 4 (확인) and is visible on the device.
--
-- Background: both 확인 and 완료 currently write the same homework_confirm RPC
-- (phase=4). The "완료 예정" intent only lived in Flutter memory
-- (_autoCompleteOnNextWaiting), so neither the server nor the M5 could tell a
-- phase-4 group that will merely cycle (확인 → 3 segments) from one that will be
-- completed next waiting (완료 → 4 segments).
--
-- This migration persists the intent on homework_items.pending_complete and
-- exposes a per-group flag the gateway merges into the M5 payload (mirrors the
-- m5_group_test_naesin_flags pattern; the big list RPCs stay untouched).

alter table public.homework_items
  add column if not exists pending_complete boolean not null default false;

-- Grader sets/clears the "완료 예정" intent for a batch of items.
create or replace function public.homework_set_pending_complete(
  p_academy_id uuid,
  p_item_ids uuid[],
  p_value boolean
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer := 0;
begin
  if p_academy_id is null or p_item_ids is null or array_length(p_item_ids, 1) is null then
    return 0;
  end if;

  update public.homework_items hi
     set pending_complete = coalesce(p_value, false),
         updated_at = now()
   where hi.academy_id = p_academy_id
     and hi.id = any(p_item_ids)
     and hi.completed_at is null
     and coalesce(hi.status, 0) <> 1;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

revoke all on function public.homework_set_pending_complete(uuid, uuid[], boolean) from public;
grant execute on function public.homework_set_pending_complete(uuid, uuid[], boolean) to anon, authenticated;

-- Per-group pending_complete flag (true when any active child is marked 완료 예정).
create or replace function public.m5_group_pending_complete_flags(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  group_id uuid,
  pending_complete boolean
) as $$
begin
  return query
  select
    gi.group_id,
    bool_or(coalesce(h.pending_complete, false)) as pending_complete
  from public.homework_group_items gi
  join public.homework_items h
    on h.id = gi.homework_item_id
   and h.academy_id = gi.academy_id
   and h.student_id = gi.student_id
  where gi.academy_id = p_academy_id
    and gi.student_id = p_student_id
    and h.completed_at is null
    and coalesce(h.status, 0) <> 1
  group by gi.group_id;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_group_pending_complete_flags(uuid, uuid) to anon, authenticated;
