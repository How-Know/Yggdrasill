-- Mark unpaid cycles as waived (e.g. leave of absence) instead of deleting rows.
-- Payment management dialog skips waived cycles; history list hides them.

alter table if exists public.payment_records
  add column if not exists waived_at date;

comment on column public.payment_records.waived_at is
  'When set, this cycle is exempt from billing (e.g. student on leave).';

create or replace function public.waive_payment_cycle(
  p_student_id uuid,
  p_cycle integer,
  p_due date default null,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer as $$
declare
  v_academy uuid := p_academy_id;
  v_due date;
  v_reg date;
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;

  if exists (
    select 1 from public.payment_records pr
    where pr.academy_id = v_academy
      and pr.student_id = p_student_id
      and pr.cycle = p_cycle
      and pr.paid_date is not null
  ) then
    raise exception 'Paid payment record cannot be waived.' using errcode = '22000';
  end if;

  v_due := p_due;
  if v_due is null then
    select (select registration_date::date
            from public.student_payment_info spi
            where spi.student_id = p_student_id)
      into v_reg;
    if v_reg is null then
      v_reg := current_date;
    end if;
    v_due := public.add_months_eom(v_reg, p_cycle - 1);
  end if;

  insert into public.payment_records(
    id, academy_id, student_id, cycle, due_date, waived_at
  )
  values (gen_random_uuid(), v_academy, p_student_id, p_cycle, v_due, current_date)
  on conflict (academy_id, student_id, cycle)
  do update set waived_at = current_date
  where public.payment_records.paid_date is null;
end$$;

-- Backward-compatible alias: delete -> waive (no longer removes rows).
create or replace function public.delete_unpaid_payment(
  p_student_id uuid,
  p_cycle integer,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer as $$
begin
  perform public.waive_payment_cycle(
    p_student_id, p_cycle, null::date, p_academy_id
  );
end$$;
