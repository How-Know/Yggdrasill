-- Clear a recorded paid date without removing the cycle or due date.

create or replace function public.clear_paid_date(
  p_student_id uuid,
  p_cycle integer,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid := p_academy_id;
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;

  update public.payment_records
  set paid_date = null
  where academy_id = v_academy
    and student_id = p_student_id
    and cycle = p_cycle
    and paid_date is not null;

  if not found then
    raise exception 'Paid payment record not found for clear.' using errcode = '22000';
  end if;
end$$;

grant execute on function public.clear_paid_date(uuid, integer, uuid) to authenticated;
