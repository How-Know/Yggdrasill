-- 20260430224500: assigned textbook problem snapshots for homework
--
-- Stores the exact migrated-textbook problems assigned in a homework item.
-- This is the canonical source for new problem-level grading and a stable
-- anchor for future iPad solve logs / analytics.

create table if not exists public.homework_item_problems (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,

  crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  pb_question_uid uuid,

  sort_order integer not null,
  problem_number text not null default '',
  problem_number_numeric integer,
  question_label text not null default '',
  page_number integer,
  display_page integer,
  raw_page integer,

  big_order integer,
  mid_order integer,
  sub_key text not null default '',
  big_name text not null default '',
  mid_name text not null default '',
  content_group_kind text not null default 'none',
  content_group_label text not null default '',
  content_group_title text not null default '',
  type_group_key text not null default '',
  type_group_label text not null default '',

  bbox_1k integer[],
  item_region_1k integer[],
  crop_snapshot jsonb not null default '{}'::jsonb,

  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,

  constraint homework_item_problems_sort_order_chk
    check (sort_order >= 1),
  constraint homework_item_problems_problem_number_numeric_chk
    check (problem_number_numeric is null or problem_number_numeric >= 1),
  constraint homework_item_problems_display_page_chk
    check (display_page is null or display_page >= 1),
  constraint homework_item_problems_page_number_chk
    check (page_number is null or page_number >= 1),
  constraint homework_item_problems_raw_page_chk
    check (raw_page is null or raw_page >= 1),
  constraint homework_item_problems_content_group_kind_chk
    check (content_group_kind in ('none', 'basic_subtopic', 'type'))
);

create unique index if not exists uidx_homework_item_problems_item_order
  on public.homework_item_problems(academy_id, homework_item_id, sort_order);

create unique index if not exists uidx_homework_item_problems_item_crop
  on public.homework_item_problems(academy_id, homework_item_id, crop_id)
  where crop_id is not null;

create index if not exists idx_homework_item_problems_item
  on public.homework_item_problems(homework_item_id, sort_order);

create index if not exists idx_homework_item_problems_student
  on public.homework_item_problems(academy_id, student_id);

create index if not exists idx_homework_item_problems_crop
  on public.homework_item_problems(academy_id, crop_id)
  where crop_id is not null;

create index if not exists idx_homework_item_problems_pb_uid
  on public.homework_item_problems(academy_id, pb_question_uid)
  where pb_question_uid is not null;

create index if not exists idx_homework_item_problems_book_problem
  on public.homework_item_problems(
    academy_id,
    book_id,
    grade_label,
    problem_number
  );

alter table public.homework_item_problems enable row level security;

drop policy if exists homework_item_problems_all on public.homework_item_problems;
create policy homework_item_problems_all on public.homework_item_problems for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_item_problems.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = homework_item_problems.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_homework_item_problems_audit
  on public.homework_item_problems;
create trigger trg_homework_item_problems_audit
before insert or update on public.homework_item_problems
for each row execute function public._set_audit_fields();
