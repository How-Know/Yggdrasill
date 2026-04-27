-- Problem bank set/item/delivery-unit model.
--
-- Existing pb_questions.meta set fields stay as a compatibility layer. These
-- tables make the long-lived 출제 단위 explicit so independent sets can expose
-- selectable items while dependent sets remain bundle-only.

create table if not exists public.pb_question_sets (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  source_document_id uuid references public.pb_documents(id) on delete cascade,
  set_key text not null,
  set_type text not null default 'dependent_set',
  common_stem text not null default '',
  render_policy jsonb not null default '{}'::jsonb,
  source_meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pb_question_sets_set_type_chk check (
    set_type in ('independent_set', 'dependent_set', 'mixed_set')
  ),
  constraint pb_question_sets_key_nonempty_chk check (btrim(set_key) <> '')
);

create unique index if not exists idx_pb_question_sets_academy_doc_key
  on public.pb_question_sets (
    academy_id,
    (coalesce(source_document_id, '00000000-0000-0000-0000-000000000000'::uuid)),
    set_key
  );
create index if not exists idx_pb_question_sets_source_document
  on public.pb_question_sets (source_document_id);
create index if not exists idx_pb_question_sets_type
  on public.pb_question_sets (academy_id, set_type);

create table if not exists public.pb_question_set_items (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  set_id uuid not null references public.pb_question_sets(id) on delete cascade,
  question_id uuid references public.pb_questions(id) on delete cascade,
  question_uid uuid,
  sub_label text not null default '',
  item_order integer not null default 0,
  dependency_group_key text not null default '',
  item_role text not null default 'item',
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pb_question_set_items_role_chk check (
    item_role in ('common_stem', 'item', 'subitem')
  )
);

create unique index if not exists idx_pb_question_set_items_order
  on public.pb_question_set_items (set_id, item_order, (coalesce(nullif(sub_label, ''), id::text)));
create index if not exists idx_pb_question_set_items_question
  on public.pb_question_set_items (set_id, question_id)
  where question_id is not null;
create index if not exists idx_pb_question_set_items_academy_question
  on public.pb_question_set_items (academy_id, question_id);
create index if not exists idx_pb_question_set_items_group
  on public.pb_question_set_items (set_id, dependency_group_key, item_order);

create table if not exists public.pb_delivery_units (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  source_document_id uuid references public.pb_documents(id) on delete cascade,
  set_id uuid references public.pb_question_sets(id) on delete cascade,
  question_id uuid references public.pb_questions(id) on delete cascade,
  delivery_key text not null,
  delivery_type text not null default 'single',
  title text not null default '',
  selectable boolean not null default true,
  item_refs jsonb not null default '[]'::jsonb,
  render_policy jsonb not null default '{}'::jsonb,
  source_meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pb_delivery_units_type_chk check (
    delivery_type in ('single', 'independent_item', 'dependent_bundle', 'mixed_bundle')
  ),
  constraint pb_delivery_units_key_nonempty_chk check (btrim(delivery_key) <> ''),
  constraint pb_delivery_units_item_refs_array_chk check (jsonb_typeof(item_refs) = 'array')
);

create unique index if not exists idx_pb_delivery_units_academy_key
  on public.pb_delivery_units (academy_id, delivery_key);
create index if not exists idx_pb_delivery_units_set
  on public.pb_delivery_units (set_id, delivery_type);
create index if not exists idx_pb_delivery_units_question
  on public.pb_delivery_units (academy_id, question_id);
create index if not exists idx_pb_delivery_units_selectable
  on public.pb_delivery_units (academy_id, selectable);

drop trigger if exists pb_question_sets_set_updated_at on public.pb_question_sets;
create trigger pb_question_sets_set_updated_at
before update on public.pb_question_sets
for each row execute function public.set_updated_at();

drop trigger if exists pb_question_set_items_set_updated_at on public.pb_question_set_items;
create trigger pb_question_set_items_set_updated_at
before update on public.pb_question_set_items
for each row execute function public.set_updated_at();

drop trigger if exists pb_delivery_units_set_updated_at on public.pb_delivery_units;
create trigger pb_delivery_units_set_updated_at
before update on public.pb_delivery_units
for each row execute function public.set_updated_at();

alter table public.pb_question_sets enable row level security;
alter table public.pb_question_set_items enable row level security;
alter table public.pb_delivery_units enable row level security;

drop policy if exists "pb_question_sets_select" on public.pb_question_sets;
drop policy if exists "pb_question_sets_insert" on public.pb_question_sets;
drop policy if exists "pb_question_sets_update" on public.pb_question_sets;
drop policy if exists "pb_question_sets_delete" on public.pb_question_sets;

create policy "pb_question_sets_select" on public.pb_question_sets
for select using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_sets_insert" on public.pb_question_sets
for insert with check (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_sets_update" on public.pb_question_sets
for update using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_sets_delete" on public.pb_question_sets
for delete using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);

drop policy if exists "pb_question_set_items_select" on public.pb_question_set_items;
drop policy if exists "pb_question_set_items_insert" on public.pb_question_set_items;
drop policy if exists "pb_question_set_items_update" on public.pb_question_set_items;
drop policy if exists "pb_question_set_items_delete" on public.pb_question_set_items;

create policy "pb_question_set_items_select" on public.pb_question_set_items
for select using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_set_items_insert" on public.pb_question_set_items
for insert with check (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_set_items_update" on public.pb_question_set_items
for update using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_question_set_items_delete" on public.pb_question_set_items
for delete using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);

drop policy if exists "pb_delivery_units_select" on public.pb_delivery_units;
drop policy if exists "pb_delivery_units_insert" on public.pb_delivery_units;
drop policy if exists "pb_delivery_units_update" on public.pb_delivery_units;
drop policy if exists "pb_delivery_units_delete" on public.pb_delivery_units;

create policy "pb_delivery_units_select" on public.pb_delivery_units
for select using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_delivery_units_insert" on public.pb_delivery_units
for insert with check (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_delivery_units_update" on public.pb_delivery_units
for update using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
create policy "pb_delivery_units_delete" on public.pb_delivery_units
for delete using (
  academy_id in (select m.academy_id from public.memberships m where m.user_id = auth.uid())
);
