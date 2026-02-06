-- 20260206140000: Textbook metadata (chapters/page counts/page offset)

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

create table if not exists public.textbook_metadata (
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  page_offset integer,
  payload jsonb,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (academy_id, book_id, grade_label)
);

create index if not exists idx_textbook_metadata_academy
  on public.textbook_metadata(academy_id);

alter table public.textbook_metadata enable row level security;

drop trigger if exists trg_textbook_metadata_audit on public.textbook_metadata;
create trigger trg_textbook_metadata_audit before insert or update on public.textbook_metadata
for each row execute function public._set_audit_fields();

drop policy if exists textbook_metadata_select on public.textbook_metadata;
create policy textbook_metadata_select on public.textbook_metadata for select
using (exists (
  select 1 from public.memberships s
  where s.academy_id = textbook_metadata.academy_id and s.user_id = auth.uid()
));

drop policy if exists textbook_metadata_ins on public.textbook_metadata;
create policy textbook_metadata_ins on public.textbook_metadata for insert
with check (exists (
  select 1 from public.memberships s
  where s.academy_id = textbook_metadata.academy_id and s.user_id = auth.uid()
));

drop policy if exists textbook_metadata_upd on public.textbook_metadata;
create policy textbook_metadata_upd on public.textbook_metadata for update
using (exists (
  select 1 from public.memberships s
  where s.academy_id = textbook_metadata.academy_id and s.user_id = auth.uid()
))
with check (exists (
  select 1 from public.memberships s
  where s.academy_id = textbook_metadata.academy_id and s.user_id = auth.uid()
));

drop policy if exists textbook_metadata_del on public.textbook_metadata;
create policy textbook_metadata_del on public.textbook_metadata for delete
using (exists (
  select 1 from public.memberships s
  where s.academy_id = textbook_metadata.academy_id and s.user_id = auth.uid()
));
