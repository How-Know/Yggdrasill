-- 20251223170000: Answer key books (right side sheet)

-- Helper (idempotent)
create or replace function public._set_audit_fields()
returns trigger
language plpgsql
security definer as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_at := coalesce(new.updated_at, now());
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.version := coalesce(new.version, 1);
  elsif tg_op = 'UPDATE' then
    new.updated_at := now();
    new.updated_by := auth.uid();
    new.version := coalesce(old.version, 1) + 1;
  end if;
  return new;
end$$;

create table if not exists public.answer_key_books (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  description text,
  grade_key text,
  order_index integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_answer_key_books_academy on public.answer_key_books(academy_id);

alter table public.answer_key_books enable row level security;

drop trigger if exists trg_answer_key_books_audit on public.answer_key_books;
create trigger trg_answer_key_books_audit before insert or update on public.answer_key_books
for each row execute function public._set_audit_fields();

drop policy if exists answer_key_books_select on public.answer_key_books;
create policy answer_key_books_select on public.answer_key_books for select
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_books.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_books_ins on public.answer_key_books;
create policy answer_key_books_ins on public.answer_key_books for insert
with check (exists (select 1 from public.memberships s where s.academy_id = answer_key_books.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_books_upd on public.answer_key_books;
create policy answer_key_books_upd on public.answer_key_books for update
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_books.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = answer_key_books.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_books_del on public.answer_key_books;
create policy answer_key_books_del on public.answer_key_books for delete
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_books.academy_id and s.user_id = auth.uid()));


