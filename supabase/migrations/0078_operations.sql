-- Placeholder migration for remote 0078_operations
-- Already applied on remote; kept empty locally for version alignment.

-- Operations master table
create extension if not exists pgcrypto
create table if not exists public.operations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
)
create unique index if not exists operations_name_key on public.operations (name)
-- Seed common operations (idempotent)
insert into public.operations (name)
values ('덧셈'), ('뺄셈'), ('곱셈'), ('나눗셈')
on conflict (name) do nothing