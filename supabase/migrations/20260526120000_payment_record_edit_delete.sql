-- Allow paid_date-only edits on paid payment records; add RPCs for paid date update and unpaid cycle delete.

create or replace function public._payment_block_edit_when_paid()
returns trigger
language plpgsql
security definer as $$
begin
  if old.paid_date is not null then
    if new.due_date is distinct from old.due_date
       or new.cycle is distinct from old.cycle then
      raise exception 'Paid payment record cannot be modified.' using errcode = '22000';
    end if;
  end if;
  return new;
end$$;

create or replace function public.update_paid_date(
  p_student_id uuid,
  p_cycle integer,
  p_paid date,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer as $$
declare
  v_academy uuid := p_academy_id;
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;

  update public.payment_records
  set paid_date = p_paid
  where academy_id = v_academy
    and student_id = p_student_id
    and cycle = p_cycle
    and paid_date is not null;

  if not found then
    raise exception 'Paid payment record not found for update.' using errcode = '22000';
  end if;
end$$;

create or replace function public.delete_unpaid_payment(
  p_student_id uuid,
  p_cycle integer,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer as $$
declare
  v_academy uuid := p_academy_id;
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;

  delete from public.payment_records
  where academy_id = v_academy
    and student_id = p_student_id
    and cycle = p_cycle
    and paid_date is null;

  if not found then
    raise exception 'Unpaid payment record not found for delete.' using errcode = '22000';
  end if;
end$$;
