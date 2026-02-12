-- 20260212102000: save student level snapshots on homework_complete

alter table public.homework_items
  add column if not exists student_level_current_snapshot smallint,
  add column if not exists student_level_target_snapshot smallint;

create index if not exists idx_homework_items_level_snapshots
  on public.homework_items(
    academy_id,
    student_level_current_snapshot,
    student_level_target_snapshot
  );

create or replace function public.homework_complete(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
set search_path = public as $$
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
end;
$$;

revoke all on function public.homework_complete(uuid,uuid) from public;
grant execute on function public.homework_complete(uuid,uuid) to anon, authenticated;

