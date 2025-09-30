-- Fix: init_first_due should create cycles 1..3 only (not 1..4)
-- Also safe to re-run: create or replace updates the function body.

create or replace function public.init_first_due(p_student_id uuid, p_first_due date, p_academy_id uuid default null)
returns void
language plpgsql
security definer as $$
declare
  v_academy uuid := p_academy_id;
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;
  insert into public.payment_records(id, academy_id, student_id, cycle, due_date)
  values (gen_random_uuid(), v_academy, p_student_id, 1, p_first_due)
  on conflict (academy_id, student_id, cycle)
  do update set due_date = excluded.due_date
  where public.payment_records.paid_date is null;

  -- ensure only next 2 future cycles (2 and 3)
  perform public._payment_ensure_future_cycles(v_academy, p_student_id, 1, p_first_due, 2);
end$$;





