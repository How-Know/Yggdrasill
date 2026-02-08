-- 20260207170000: homework_items check_count + confirm increment

alter table public.homework_items
  add column if not exists check_count integer not null default 0;

update public.homework_items
  set check_count = 0
  where check_count is null;

-- 확인 시 검사 횟수 증가
create or replace function public.homework_confirm(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
as $$
begin
  update public.homework_items
     set phase = 4,
         confirmed_at = now(),
         updated_at = now(),
         version = coalesce(version, 1) + 1,
         check_count = coalesce(check_count, 0) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 4::smallint, null::text);
end;
$$;
