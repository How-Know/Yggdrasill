-- 20260209153000: homework_confirm increments check_count

create or replace function public.homework_confirm(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
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
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version,1) + 1,
         check_count   = coalesce(check_count, 0) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 4::smallint, null::text);
end$$;

revoke all on function public.homework_confirm(uuid,uuid,text) from public;
grant execute on function public.homework_confirm(uuid,uuid,text) to anon, authenticated;
