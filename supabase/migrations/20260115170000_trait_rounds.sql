-- Trait survey rounds/parts (design tool)

create table if not exists public.trait_rounds (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  order_index int not null default 0,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_trait_rounds_updated_at on public.trait_rounds;
create trigger set_trait_rounds_updated_at
before update on public.trait_rounds
for each row execute function public.set_updated_at();

create table if not exists public.trait_round_parts (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.trait_rounds(id) on delete cascade,
  name text not null,
  description text,
  image_url text,
  order_index int not null default 0,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_trait_round_parts_updated_at on public.trait_round_parts;
create trigger set_trait_round_parts_updated_at
before update on public.trait_round_parts
for each row execute function public.set_updated_at();

create index if not exists idx_trait_rounds_order on public.trait_rounds(order_index);
create index if not exists idx_trait_round_parts_round_order on public.trait_round_parts(round_id, order_index);

alter table public.trait_rounds enable row level security;
alter table public.trait_round_parts enable row level security;

-- Admin-only (authenticated) manage
drop policy if exists "Admins read trait_rounds" on public.trait_rounds;
create policy "Admins read trait_rounds"
on public.trait_rounds for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_rounds" on public.trait_rounds;
create policy "Admins manage trait_rounds"
on public.trait_rounds for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

drop policy if exists "Admins read trait_round_parts" on public.trait_round_parts;
create policy "Admins read trait_round_parts"
on public.trait_round_parts for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_round_parts" on public.trait_round_parts;
create policy "Admins manage trait_round_parts"
on public.trait_round_parts for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

