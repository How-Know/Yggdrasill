-- Waive = delete unpaid cycle row + renumber later cycles (due_date preserved).
-- Backfill existing waived_at rows for all students.

-- Paid rows: due_date locked; cycle renumber + paid_date edit allowed.
create or replace function public._payment_block_edit_when_paid()
returns trigger
language plpgsql
security definer as $$
begin
  if old.paid_date is not null then
    if new.due_date is distinct from old.due_date then
      raise exception 'Paid payment record cannot be modified.' using errcode = '22000';
    end if;
  end if;
  return new;
end$$;

create or replace function public._payment_renumber_cycles_after_delete(
  p_academy_id uuid,
  p_student_id uuid,
  p_deleted_cycle integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- unique (academy_id, student_id, cycle) 충돌 방지: 임시 오프셋 후 재번호
  update public.payment_records
  set cycle = cycle + 100000
  where academy_id = p_academy_id
    and student_id = p_student_id
    and cycle > p_deleted_cycle;

  update public.payment_records
  set cycle = cycle - 100001
  where academy_id = p_academy_id
    and student_id = p_student_id
    and cycle > 100000;

  update public.student_charge_points
  set cycle = cycle + 100000
  where academy_id = p_academy_id
    and student_id = p_student_id
    and cycle > p_deleted_cycle;

  update public.student_charge_points
  set cycle = cycle - 100001
  where academy_id = p_academy_id
    and student_id = p_student_id
    and cycle > 100000;
end;
$$;

create or replace function public.waive_payment_cycle(
  p_student_id uuid,
  p_cycle integer,
  p_due date default null,
  p_academy_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid := p_academy_id;
  v_deleted integer;
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

  delete from public.payment_records
  where academy_id = v_academy
    and student_id = p_student_id
    and cycle = p_cycle
    and paid_date is null;

  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'Unpaid payment record not found for waive.' using errcode = '22000';
  end if;

  perform public._payment_renumber_cycles_after_delete(
    v_academy, p_student_id, p_cycle
  );
end;
$$;

-- One-time: delete all legacy waived_at rows and renumber remaining cycles per student.
do $$
begin
  create temp table _payment_waived_to_drop on commit drop as
  select pr.academy_id, pr.student_id, pr.cycle
  from public.payment_records pr
  where pr.waived_at is not null
    and pr.paid_date is null;

  delete from public.payment_records pr
  using _payment_waived_to_drop w
  where pr.academy_id = w.academy_id
    and pr.student_id = w.student_id
    and pr.cycle = w.cycle
    and pr.paid_date is null;

  update public.payment_records pr
  set cycle = pr.cycle + 100000
  where exists (
    select 1 from _payment_waived_to_drop w
    where w.academy_id = pr.academy_id
      and w.student_id = pr.student_id
      and w.cycle < pr.cycle
  );

  update public.payment_records pr
  set cycle = pr.cycle - 100000 - wdrop.cnt
  from (
    select pr2.academy_id,
           pr2.student_id,
           pr2.cycle,
           count(w.cycle) as cnt
    from public.payment_records pr2
    join _payment_waived_to_drop w
      on w.academy_id = pr2.academy_id
     and w.student_id = pr2.student_id
     and w.cycle < (pr2.cycle - 100000)
    where pr2.cycle > 100000
    group by pr2.academy_id, pr2.student_id, pr2.cycle
  ) wdrop
  where pr.academy_id = wdrop.academy_id
    and pr.student_id = wdrop.student_id
    and pr.cycle = wdrop.cycle;

  update public.student_charge_points scp
  set cycle = scp.cycle + 100000
  where exists (
    select 1 from _payment_waived_to_drop w
    where w.academy_id = scp.academy_id
      and w.student_id = scp.student_id
      and w.cycle < scp.cycle
  );

  update public.student_charge_points scp
  set cycle = scp.cycle - 100000 - wdrop.cnt
  from (
    select scp2.academy_id,
           scp2.student_id,
           scp2.cycle,
           count(w.cycle) as cnt
    from public.student_charge_points scp2
    join _payment_waived_to_drop w
      on w.academy_id = scp2.academy_id
     and w.student_id = scp2.student_id
     and w.cycle < (scp2.cycle - 100000)
    where scp2.cycle > 100000
    group by scp2.academy_id, scp2.student_id, scp2.cycle
  ) wdrop
  where scp.academy_id = wdrop.academy_id
    and scp.student_id = wdrop.student_id
    and scp.cycle = wdrop.cycle;
end;
$$;
