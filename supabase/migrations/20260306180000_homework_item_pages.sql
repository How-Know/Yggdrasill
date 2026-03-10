-- 20260306180000: homework_item_pages for page-level stats

create table if not exists public.homework_item_pages (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  page_number integer not null,
  problem_count integer not null default 0,
  allocated_ms bigint not null default 0,
  allocated_checks numeric(10, 4) not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create unique index if not exists uidx_homework_item_pages_unique
  on public.homework_item_pages(academy_id, homework_item_id, page_number);

create index if not exists idx_homework_item_pages_book_grade_page
  on public.homework_item_pages(academy_id, book_id, grade_label, page_number);

create index if not exists idx_homework_item_pages_student
  on public.homework_item_pages(academy_id, student_id);

create index if not exists idx_homework_item_pages_item
  on public.homework_item_pages(homework_item_id);

alter table public.homework_item_pages enable row level security;

drop policy if exists homework_item_pages_all on public.homework_item_pages;
create policy homework_item_pages_all on public.homework_item_pages for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_item_pages.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_item_pages.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_homework_item_pages_audit on public.homework_item_pages;
create trigger trg_homework_item_pages_audit before insert or update on public.homework_item_pages
for each row execute function public._set_audit_fields();
