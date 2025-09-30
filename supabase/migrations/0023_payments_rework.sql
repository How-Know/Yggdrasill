-- Payments rework: normalize dates to DATE, EOM handling, rules & RPCs
-- - Convert due_date/paid_date to DATE
-- - Unique key (academy_id, student_id, cycle)
-- - Triggers: immutability after paid, postpone cascade, ensure next 3 cycles
-- - Helper: add_months_eom(d, n)
-- - RPCs: init_first_due, record_payment, postpone_due_date

-- Helper: add months with end-of-month rule (if original day is missing in target month,
-- move to the first day of the next month)
create or replace function public.add_months_eom(p_base date, p_months integer)
returns date
language plpgsql
immutable
as $$
declare
  v_year integer := extract(year from p_base)::int;
  v_month integer := extract(month from p_base)::int;
  v_day integer := extract(day from p_base)::int;
  t_year integer;
  t_month integer;
  days_in_target integer;
  target date;
begin
  t_year := v_year + ((v_month - 1 + p_months) / 12);
  t_month := ((v_month - 1 + p_months) % 12) + 1;

  -- last day of target month
  days_in_target := extract(day from (date_trunc('month', (make_date(t_year, t_month, 1) + interval '1 month')::timestamp) - interval '1 day'))::int;

  if v_day <= days_in_target then
    target := make_date(t_year, t_month, v_day);
  else
    -- move to the 1st of the following month
    t_year := t_year + ((t_month) / 12);
    t_month := ((t_month) % 12) + 1;
    target := make_date(t_year, t_month, 1);
  end if;

  return target;
end$$;

-- Normalize column types to DATE (robust against existing bigint epoch ms or timestamptz)
alter table if exists public.payment_records
  alter column due_date type date using (
    case
      when due_date is null then null
      when (due_date::text ~ '^[0-9]+$') then to_timestamp((((due_date)::text)::bigint)/1000)::date
      else (due_date::timestamptz)::date
    end
  );

alter table if exists public.payment_records
  alter column paid_date type date using (
    case
      when paid_date is null then null
      when (paid_date::text ~ '^[0-9]+$') then to_timestamp((((paid_date)::text)::bigint)/1000)::date
      else (paid_date::timestamptz)::date
    end
  );

-- Add unique index on (academy_id, student_id, cycle)
create unique index if not exists uq_payment_records_academy_student_cycle
  on public.payment_records(academy_id, student_id, cycle);

-- Trigger: block edits after paid
create or replace function public._payment_block_edit_when_paid()
returns trigger
language plpgsql
security definer as $$
begin
  if old.paid_date is not null then
    if new.due_date is distinct from old.due_date or new.cycle is distinct from old.cycle or new.paid_date is distinct from old.paid_date then
      raise exception 'Paid payment record cannot be modified.' using errcode = '22000';
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_payment_records_lock_after_paid on public.payment_records;
create trigger trg_payment_records_lock_after_paid
before update on public.payment_records
for each row execute function public._payment_block_edit_when_paid();

-- Trigger: when due_date of an UNPAID record changes, cascade recalculation to future unpaid cycles
create or replace function public._payment_postpone_cascade()
returns trigger
language plpgsql
security definer as $$
begin
  if new.paid_date is null and (new.due_date is distinct from old.due_date) then
    update public.payment_records pr
    set due_date = public.add_months_eom(new.due_date, pr.cycle - new.cycle)
    where pr.academy_id = new.academy_id
      and pr.student_id = new.student_id
      and pr.cycle > new.cycle
      and pr.paid_date is null;
  end if;
  return new;
end$$;

drop trigger if exists trg_payment_records_postpone_cascade on public.payment_records;
create trigger trg_payment_records_postpone_cascade
after update of due_date on public.payment_records
for each row execute function public._payment_postpone_cascade();

-- Helper: ensure next N future unpaid cycles exist starting from a base record
create or replace function public._payment_ensure_future_cycles(p_academy_id uuid, p_student_id uuid, p_from_cycle integer, p_from_due date, p_count integer)
returns void
language plpgsql
security definer as $$
declare
  i integer;
  target_cycle integer;
  target_due date;
begin
  for i in 1..p_count loop
    target_cycle := p_from_cycle + i;
    target_due := public.add_months_eom(p_from_due, i);
    insert into public.payment_records(id, academy_id, student_id, cycle, due_date)
    values (gen_random_uuid(), p_academy_id, p_student_id, target_cycle, target_due)
    on conflict (academy_id, student_id, cycle)
    do nothing;
  end loop;
end$$;

-- Trigger: after payment, ensure next 3 cycles exist
create or replace function public._payment_generate_future_after_paid()
returns trigger
language plpgsql
security definer as $$
begin
  if new.paid_date is not null then
    perform public._payment_ensure_future_cycles(new.academy_id, new.student_id, new.cycle, new.due_date, 3);
  end if;
  return new;
end$$;

drop trigger if exists trg_payment_records_generate_future on public.payment_records;
create trigger trg_payment_records_generate_future
after insert or update of paid_date on public.payment_records
for each row execute function public._payment_generate_future_after_paid();

-- RPC: initialize first due date at registration and pre-create 3 future cycles
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

  -- 초기 생성은 cycle 1만 + 미래 2회분(2,3)만 보장
  perform public._payment_ensure_future_cycles(v_academy, p_student_id, 1, p_first_due, 2);
end$$;

-- RPC: record a payment for a specific cycle and ensure future cycles
create or replace function public.record_payment(p_student_id uuid, p_cycle integer, p_paid date, p_academy_id uuid default null)
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

  -- ensure row exists with calculated due_date if missing
  select (select registration_date::date from public.student_payment_info spi where spi.student_id = p_student_id)
    into v_reg;
  if v_reg is null then
    -- fallback: today as base
    v_reg := current_date;
  end if;
  v_due := public.add_months_eom(v_reg, p_cycle - 1);

  insert into public.payment_records(id, academy_id, student_id, cycle, due_date, paid_date)
  values (gen_random_uuid(), v_academy, p_student_id, p_cycle, v_due, p_paid)
  on conflict (academy_id, student_id, cycle)
  do update set paid_date = excluded.paid_date
  where public.payment_records.paid_date is null;

  perform public._payment_ensure_future_cycles(v_academy, p_student_id, p_cycle, v_due, 3);
end$$;

-- RPC: postpone due date for an unpaid cycle and cascade to future unpaid cycles
create or replace function public.postpone_due_date(p_student_id uuid, p_cycle integer, p_new_due date, p_reason text default '', p_academy_id uuid default null)
returns void
language plpgsql
security definer as $$
declare
  v_academy uuid := p_academy_id;
  v_old_due date;
  v_append text := coalesce(p_reason, '');
begin
  if v_academy is null then
    select academy_id into v_academy from public.students where id = p_student_id;
  end if;

  -- only unpaid can be postponed
  update public.payment_records
  set due_date = p_new_due,
      postpone_reason = trim(both from coalesce(postpone_reason || E'\n', '') || to_char(current_date, 'YYYY-MM-DD') || ' : ' || v_append)
  where academy_id = v_academy and student_id = p_student_id and cycle = p_cycle and paid_date is null
  returning due_date into v_old_due;

  -- cascade recalculation to future unpaid cycles
  update public.payment_records pr
  set due_date = public.add_months_eom(p_new_due, pr.cycle - p_cycle)
  where pr.academy_id = v_academy and pr.student_id = p_student_id and pr.cycle > p_cycle and pr.paid_date is null;
end$$;


