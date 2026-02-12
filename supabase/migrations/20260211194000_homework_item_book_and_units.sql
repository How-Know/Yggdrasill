-- 20260211194000: homework_items textbook keys + homework_item_units mapping

alter table public.homework_items
  add column if not exists book_id uuid references public.resource_files(id) on delete set null,
  add column if not exists grade_label text,
  add column if not exists source_unit_level text,
  add column if not exists source_unit_path text;

create index if not exists idx_homework_items_book_grade
  on public.homework_items(academy_id, book_id, grade_label);
create index if not exists idx_homework_items_source_unit_level
  on public.homework_items(academy_id, source_unit_level);

create table if not exists public.homework_item_units (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  big_order integer not null,
  mid_order integer not null,
  small_order integer not null,
  big_name text not null,
  mid_name text not null,
  small_name text not null,
  start_page integer,
  end_page integer,
  page_count integer,
  weight numeric(10, 6) not null default 1,
  source_scope text not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint chk_homework_item_units_source_scope
    check (source_scope in ('direct_small', 'expanded_from_mid', 'expanded_from_big'))
);

create unique index if not exists uidx_homework_item_units_unique
  on public.homework_item_units(academy_id, homework_item_id, big_order, mid_order, small_order);
create index if not exists idx_homework_item_units_book_grade_unit
  on public.homework_item_units(academy_id, book_id, grade_label, big_order, mid_order, small_order);
create index if not exists idx_homework_item_units_student
  on public.homework_item_units(academy_id, student_id);
create index if not exists idx_homework_item_units_item
  on public.homework_item_units(homework_item_id);

alter table public.homework_item_units enable row level security;
drop policy if exists homework_item_units_all on public.homework_item_units;
create policy homework_item_units_all on public.homework_item_units for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_item_units.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_item_units.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_homework_item_units_audit on public.homework_item_units;
create trigger trg_homework_item_units_audit before insert or update on public.homework_item_units
for each row execute function public._set_audit_fields();

