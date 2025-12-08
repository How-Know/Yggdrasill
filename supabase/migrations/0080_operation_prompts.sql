-- Placeholder migration for remote 0080_operation_prompts
-- Already applied on remote; kept empty locally for version alignment.

-- Prompts per existing concept (sub_type='연산')
create extension if not exists pgcrypto
create table if not exists public.operation_prompts (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  level_label text not null,
  prompt text not null default '',
  sort_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
)
create index if not exists operation_prompts_concept_idx on public.operation_prompts (concept_id)
create unique index if not exists operation_prompts_unique_label on public.operation_prompts (concept_id, level_label)