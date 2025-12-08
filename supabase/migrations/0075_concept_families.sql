-- Placeholder migration for remote 0075_concept_families
-- Already applied on remote; kept empty locally for version alignment.

-- Create concept_families table for grouping same-name concepts
create extension if not exists pgcrypto
create table if not exists public.concept_families (
  id uuid primary key default gen_random_uuid(),
  canonical_name text not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
)
-- Ensure canonical name uniqueness
create unique index if not exists concept_families_canonical_name_key on public.concept_families (canonical_name)