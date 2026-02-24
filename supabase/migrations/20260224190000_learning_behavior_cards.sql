-- 학습 > 커리큘럼(행동 카드) 저장 테이블

create table if not exists public.learning_behavior_cards (
  id uuid primary key default gen_random_uuid(),
  academy_id text not null,
  name text not null,
  repeat_days int not null check (repeat_days >= 1),
  is_irregular boolean not null default false,
  level_contents jsonb not null default '[]'::jsonb,
  selected_level_index int not null default 0 check (selected_level_index >= 0),
  icon_code int not null,
  color int not null,
  order_index int not null default 0,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table if exists public.learning_behavior_cards
  add column if not exists is_irregular boolean not null default false;

create index if not exists idx_learning_behavior_cards_academy
  on public.learning_behavior_cards (academy_id);

create index if not exists idx_learning_behavior_cards_academy_order
  on public.learning_behavior_cards (academy_id, order_index);

drop trigger if exists trg_learning_behavior_cards_updated_at
  on public.learning_behavior_cards;
create trigger trg_learning_behavior_cards_updated_at
before update on public.learning_behavior_cards
for each row execute function public.set_updated_at();

alter table public.learning_behavior_cards enable row level security;

drop policy if exists "Read learning_behavior_cards" on public.learning_behavior_cards;
create policy "Read learning_behavior_cards"
on public.learning_behavior_cards for select
to authenticated
using (auth.role() = 'authenticated');

drop policy if exists "Manage learning_behavior_cards" on public.learning_behavior_cards;
create policy "Manage learning_behavior_cards"
on public.learning_behavior_cards for all
to authenticated
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');
