-- Structured homework grading states.
--
-- UI semantics:
--   correct                         = 정답
--   wrong + incorrect_kind=answered = 오답(답함)
--   wrong + incorrect_kind=blank    = 미풀이(점수상 오답)
--   not_performed                   = 미수행
--
-- Legacy `unsolved` meant a blank/unattempted answer, not non-performance.
-- Preserve that meaning by migrating it to wrong+blank.

alter table public.homework_test_grading_attempt_items
  add column if not exists incorrect_kind text;

alter table public.homework_test_grading_attempts
  add column if not exists blank_count integer not null default 0,
  add column if not exists not_performed_count integer not null default 0;

update public.homework_test_grading_attempt_items
set state = 'wrong',
    incorrect_kind = 'blank'
where state = 'unsolved';

update public.homework_test_grading_attempt_items
set incorrect_kind = 'answered'
where state = 'wrong'
  and incorrect_kind is null;

update public.homework_test_grading_attempt_items
set baseline_state = 'wrong'
where baseline_state = 'unsolved';

alter table public.homework_test_grading_attempt_items
  drop constraint if exists hw_test_grading_attempt_items_state_chk,
  drop constraint if exists hw_test_grading_attempt_items_incorrect_kind_chk,
  drop constraint if exists hw_test_grading_attempt_items_state_kind_chk,
  drop constraint if exists hw_test_grading_attempt_items_baseline_state_chk;

alter table public.homework_test_grading_attempt_items
  add constraint hw_test_grading_attempt_items_state_chk
    check (state in ('correct', 'wrong', 'not_performed')),
  add constraint hw_test_grading_attempt_items_incorrect_kind_chk
    check (
      incorrect_kind is null
      or incorrect_kind in ('answered', 'blank', 'unknown')
    ),
  add constraint hw_test_grading_attempt_items_state_kind_chk
    check (
      -- Older app versions write wrong without a subtype. Keep those writes
      -- valid and interpret null as answered/unknown on read.
      state = 'wrong'
      or (state <> 'wrong' and incorrect_kind is null)
    ),
  add constraint hw_test_grading_attempt_items_baseline_state_chk
    check (
      baseline_state is null
      or baseline_state in ('wrong', 'not_performed')
    );

alter table public.homework_test_grading_attempts
  drop constraint if exists hw_test_grading_attempts_blank_count_chk,
  drop constraint if exists hw_test_grading_attempts_not_performed_count_chk;

alter table public.homework_test_grading_attempts
  add constraint hw_test_grading_attempts_blank_count_chk
    check (blank_count >= 0),
  add constraint hw_test_grading_attempts_not_performed_count_chk
    check (not_performed_count >= 0);

create or replace function public._normalize_homework_grading_item_state()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.state = 'unsolved' then
    new.state := 'wrong';
    new.incorrect_kind := 'blank';
  elsif new.state = 'wrong' and new.incorrect_kind is null then
    new.incorrect_kind := 'answered';
  elsif new.state <> 'wrong' then
    new.incorrect_kind := null;
  end if;
  if new.baseline_state = 'unsolved' then
    new.baseline_state := 'wrong';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_normalize_homework_grading_item_state
  on public.homework_test_grading_attempt_items;
create trigger trg_normalize_homework_grading_item_state
before insert or update of state, incorrect_kind, baseline_state
on public.homework_test_grading_attempt_items
for each row execute function public._normalize_homework_grading_item_state();

with counts as (
  select
    attempt_id,
    count(*) filter (where state = 'wrong')::integer as wrong_count,
    count(*) filter (
      where state = 'wrong' and incorrect_kind = 'blank'
    )::integer as blank_count,
    count(*) filter (where state = 'not_performed')::integer
      as not_performed_count
  from public.homework_test_grading_attempt_items
  group by attempt_id
)
update public.homework_test_grading_attempts a
set wrong_count = c.wrong_count,
    -- Keep the legacy aggregate readable for older clients.
    unsolved_count = c.blank_count,
    blank_count = c.blank_count,
    not_performed_count = c.not_performed_count
from counts c
where c.attempt_id = a.id;
