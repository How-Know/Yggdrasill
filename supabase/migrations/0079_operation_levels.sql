-- Placeholder migration for remote 0079_operation_levels
-- Already applied on remote; kept empty locally for version alignment.

-- Levels per operation with prompts
create extension if not exists pgcrypto
create table if not exists public.operation_levels (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null references public.operations(id) on delete cascade,
  level_label text not null,
  prompt text not null default '',
  sort_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
)
create index if not exists operation_levels_operation_idx on public.operation_levels (operation_id)
create index if not exists operation_levels_sort_idx on public.operation_levels (operation_id, sort_order)
create unique index if not exists operation_levels_unique_label on public.operation_levels (operation_id, level_label)