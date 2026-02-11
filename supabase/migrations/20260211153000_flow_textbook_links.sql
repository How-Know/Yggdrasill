-- 20260211153000: flow <-> textbook(grade) links

create table if not exists public.flow_textbook_links (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  flow_id uuid not null references public.student_flows(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  order_index integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create unique index if not exists uidx_flow_textbook_links_unique
  on public.flow_textbook_links(academy_id, flow_id, book_id, grade_label);
create index if not exists idx_flow_textbook_links_flow
  on public.flow_textbook_links(flow_id);
create index if not exists idx_flow_textbook_links_book
  on public.flow_textbook_links(book_id);
create index if not exists idx_flow_textbook_links_academy
  on public.flow_textbook_links(academy_id);

alter table public.flow_textbook_links enable row level security;

drop trigger if exists trg_flow_textbook_links_audit on public.flow_textbook_links;
create trigger trg_flow_textbook_links_audit
before insert or update on public.flow_textbook_links
for each row execute function public._set_audit_fields();

drop policy if exists flow_textbook_links_select on public.flow_textbook_links;
create policy flow_textbook_links_select
on public.flow_textbook_links
for select
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = flow_textbook_links.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists flow_textbook_links_ins on public.flow_textbook_links;
create policy flow_textbook_links_ins
on public.flow_textbook_links
for insert
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = flow_textbook_links.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists flow_textbook_links_upd on public.flow_textbook_links;
create policy flow_textbook_links_upd
on public.flow_textbook_links
for update
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = flow_textbook_links.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = flow_textbook_links.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists flow_textbook_links_del on public.flow_textbook_links;
create policy flow_textbook_links_del
on public.flow_textbook_links
for delete
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = flow_textbook_links.academy_id
      and s.user_id = auth.uid()
  )
);
