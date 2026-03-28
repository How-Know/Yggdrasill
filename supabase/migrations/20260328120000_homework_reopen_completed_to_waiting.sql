-- 채점 취소 등: 완료된 숙제를 다시 대기(phase 1, 진행중)로 되돌린다.
-- homework_wait는 completed_at is null 조건이라 완료 행에는 적용되지 않음.

create or replace function public.homework_reopen_completed_to_waiting(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public as $$
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
     and (coalesce(status, 0) = 1 or completed_at is not null);

  if found then
    perform public._append_homework_phase_event(
      p_academy_id,
      p_item_id,
      1::smallint,
      'reopen_from_completed'::text
    );
  end if;
end$$;

revoke all on function public.homework_reopen_completed_to_waiting(uuid, uuid, text) from public;
grant execute on function public.homework_reopen_completed_to_waiting(uuid, uuid, text) to anon, authenticated;
