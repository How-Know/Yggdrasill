-- Persist test grading attempts (header + per-question rows)

create table if not exists public.homework_test_grading_attempts (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  assignment_code_snapshot text,
  group_homework_title_snapshot text,
  graded_at timestamptz not null default now(),
  graded_by uuid,
  action text not null,
  solve_elapsed_ms integer not null default 0,
  extra_elapsed_ms integer not null default 0,
  score_correct numeric(10, 2) not null default 0,
  score_total numeric(10, 2) not null default 0,
  wrong_count integer not null default 0,
  unsolved_count integer not null default 0,
  payload_version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint hw_test_grading_attempts_action_chk
    check (action in ('complete', 'confirm')),
  constraint hw_test_grading_attempts_solve_elapsed_ms_chk
    check (solve_elapsed_ms >= 0),
  constraint hw_test_grading_attempts_extra_elapsed_ms_chk
    check (extra_elapsed_ms >= 0),
  constraint hw_test_grading_attempts_score_correct_chk
    check (score_correct >= 0),
  constraint hw_test_grading_attempts_score_total_chk
    check (score_total >= 0),
  constraint hw_test_grading_attempts_wrong_count_chk
    check (wrong_count >= 0),
  constraint hw_test_grading_attempts_unsolved_count_chk
    check (unsolved_count >= 0)
);

create index if not exists idx_hw_test_grading_attempts_academy_student_graded_at
  on public.homework_test_grading_attempts (academy_id, student_id, graded_at desc);

create index if not exists idx_hw_test_grading_attempts_academy_item_graded_at
  on public.homework_test_grading_attempts (academy_id, homework_item_id, graded_at desc);

create table if not exists public.homework_test_grading_attempt_items (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.homework_test_grading_attempts(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  question_key text not null,
  question_uid text,
  page_number integer not null,
  question_index integer not null,
  correct_answer_snapshot text,
  state text not null,
  point_value numeric(10, 2) not null default 1,
  earned_point numeric(10, 2) not null default 0,
  reserved_elapsed_ms integer,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint hw_test_grading_attempt_items_state_chk
    check (state in ('correct', 'wrong', 'unsolved')),
  constraint hw_test_grading_attempt_items_point_value_chk
    check (point_value >= 0),
  constraint hw_test_grading_attempt_items_earned_point_chk
    check (earned_point >= 0),
  constraint hw_test_grading_attempt_items_page_number_chk
    check (page_number >= 1),
  constraint hw_test_grading_attempt_items_question_index_chk
    check (question_index >= 1),
  constraint hw_test_grading_attempt_items_unique_attempt_question_key
    unique (attempt_id, question_key)
);

create index if not exists idx_hw_test_grading_items_academy_question_uid_created
  on public.homework_test_grading_attempt_items (academy_id, question_uid, created_at desc);

create index if not exists idx_hw_test_grading_items_academy_question_key_created
  on public.homework_test_grading_attempt_items (academy_id, question_key, created_at desc);

create index if not exists idx_hw_test_grading_items_attempt_page_question
  on public.homework_test_grading_attempt_items (attempt_id, page_number, question_index);

alter table public.homework_test_grading_attempts enable row level security;
alter table public.homework_test_grading_attempt_items enable row level security;

drop policy if exists homework_test_grading_attempts_all on public.homework_test_grading_attempts;
create policy homework_test_grading_attempts_all
on public.homework_test_grading_attempts
for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_test_grading_attempts.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_test_grading_attempts.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists homework_test_grading_attempt_items_all on public.homework_test_grading_attempt_items;
create policy homework_test_grading_attempt_items_all
on public.homework_test_grading_attempt_items
for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_test_grading_attempt_items.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_test_grading_attempt_items.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_hw_test_grading_attempts_audit on public.homework_test_grading_attempts;
create trigger trg_hw_test_grading_attempts_audit
before insert or update on public.homework_test_grading_attempts
for each row execute function public._set_audit_fields();

drop trigger if exists trg_hw_test_grading_attempt_items_audit on public.homework_test_grading_attempt_items;
create trigger trg_hw_test_grading_attempt_items_audit
before insert or update on public.homework_test_grading_attempt_items
for each row execute function public._set_audit_fields();
