
-- Add body and accumulated to m5_list_homeworks return
drop function if exists public.m5_list_homeworks(uuid, uuid);

create function public.m5_list_homeworks(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  item_id uuid,
  title text,
  body text,
  color bigint,
  phase smallint,
  accumulated bigint,
  submitted_at timestamptz,
  confirmed_at timestamptz,
  waiting_at timestamptz
) as $$
begin
  return query
  select 
    h.id as item_id, 
    h.title, 
    h.body,
    h.color::bigint, 
    coalesce(h.phase, 1)::smallint,
    (coalesce(h.accumulated_ms, 0) / 1000)::bigint as accumulated,
    h.submitted_at, 
    h.confirmed_at, 
    h.waiting_at
  from public.homework_items h
  where h.academy_id = p_academy_id 
    and h.student_id = p_student_id 
    and h.completed_at is null
  order by
    case coalesce(h.phase,1)
      when 2 then 0 -- performing first
      when 1 then 1 -- waiting
      when 4 then 2 -- confirmed
      when 3 then 3 -- submitted
      else 9
    end,
    coalesce(h.waiting_at, h.submitted_at, h.confirmed_at, h.first_started_at, h.created_at);
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homeworks(uuid, uuid) to anon, authenticated;
