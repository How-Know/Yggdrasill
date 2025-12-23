-- 20251223173000: Answer key book pdf links (per grade)

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

create table if not exists public.answer_key_book_pdfs (
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.answer_key_books(id) on delete cascade,
  grade_key text not null,
  path text not null,
  name text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (academy_id, book_id, grade_key)
);

create index if not exists idx_answer_key_book_pdfs_academy on public.answer_key_book_pdfs(academy_id);
create index if not exists idx_answer_key_book_pdfs_book on public.answer_key_book_pdfs(book_id);

alter table public.answer_key_book_pdfs enable row level security;

drop trigger if exists trg_answer_key_book_pdfs_audit on public.answer_key_book_pdfs;
create trigger trg_answer_key_book_pdfs_audit before insert or update on public.answer_key_book_pdfs
for each row execute function public._set_audit_fields();

drop policy if exists answer_key_book_pdfs_select on public.answer_key_book_pdfs;
create policy answer_key_book_pdfs_select on public.answer_key_book_pdfs for select
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_book_pdfs.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_book_pdfs_ins on public.answer_key_book_pdfs;
create policy answer_key_book_pdfs_ins on public.answer_key_book_pdfs for insert
with check (exists (select 1 from public.memberships s where s.academy_id = answer_key_book_pdfs.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_book_pdfs_upd on public.answer_key_book_pdfs;
create policy answer_key_book_pdfs_upd on public.answer_key_book_pdfs for update
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_book_pdfs.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = answer_key_book_pdfs.academy_id and s.user_id = auth.uid()));

drop policy if exists answer_key_book_pdfs_del on public.answer_key_book_pdfs;
create policy answer_key_book_pdfs_del on public.answer_key_book_pdfs for delete
using (exists (select 1 from public.memberships s where s.academy_id = answer_key_book_pdfs.academy_id and s.user_id = auth.uid()));


