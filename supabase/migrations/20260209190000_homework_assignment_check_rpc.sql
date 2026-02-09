-- 20260209190000: homework_assignment_check rpc

create or replace function public.homework_assignment_check(
  p_assignment_id uuid,
  p_academy_id uuid,
  p_progress integer,
  p_issue_type text default null,
  p_issue_note text default null,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public as $$
declare
  v_student_id uuid;
  v_item_id uuid;
begin
  select student_id, homework_item_id
    into v_student_id, v_item_id
  from public.homework_assignments
  where id = p_assignment_id and academy_id = p_academy_id;

  if v_student_id is null or v_item_id is null then
    return;
  end if;

  update public.homework_assignments
     set progress   = greatest(0, least(150, p_progress)),
         issue_type = p_issue_type,
         issue_note = p_issue_note,
         updated_at = now(),
         updated_by = case
           when p_updated_by is not null then p_updated_by::uuid
           else updated_by
         end,
         version    = coalesce(version, 1) + 1
   where id = p_assignment_id and academy_id = p_academy_id;

  insert into public.homework_assignment_checks (
    academy_id,
    student_id,
    homework_item_id,
    assignment_id,
    progress,
    checked_at
  ) values (
    p_academy_id,
    v_student_id,
    v_item_id,
    p_assignment_id,
    greatest(0, least(150, p_progress)),
    now()
  );

  update public.homework_items
     set check_count = coalesce(check_count, 0) + 1
   where id = v_item_id and academy_id = p_academy_id;
end$$;

revoke all on function public.homework_assignment_check(uuid,uuid,integer,text,text,text) from public;
grant execute on function public.homework_assignment_check(uuid,uuid,integer,text,text,text) to anon, authenticated;
