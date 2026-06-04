-- Expand the M5 PIN gate from a single test student (감나단) to ALL students.
--
--   1) Backfill: every existing student gets pin_required = true.
--      - Students who already set a PIN (pin_hash not null, e.g. 감나단) keep it.
--      - First login still defines the PIN (student-chosen) unless a teacher
--        sets one beforehand via m5_admin_set_student_pin.
--   2) New students inserted later are auto-enrolled into the PIN gate.
--
-- Teachers can opt an individual student out at any time via
-- m5_admin_clear_student_pin (the "해제" button in the student panel).

-- ---------------------------------------------------------------------------
-- 1) Backfill all existing students.
-- ---------------------------------------------------------------------------
insert into public.m5_student_pins (academy_id, student_id, pin_required)
select s.academy_id, s.id, true
from public.students s
where s.academy_id is not null
on conflict (student_id) do update set
  pin_required = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 2) Auto-enroll students created from now on.
-- ---------------------------------------------------------------------------
create or replace function public.m5_student_pin_default()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.academy_id is not null then
    insert into public.m5_student_pins(academy_id, student_id, pin_required)
    values (new.academy_id, new.id, true)
    on conflict (student_id) do nothing;
  end if;
  return new;
end; $$;

drop trigger if exists trg_m5_student_pin_default on public.students;
create trigger trg_m5_student_pin_default
  after insert on public.students
  for each row execute function public.m5_student_pin_default();
