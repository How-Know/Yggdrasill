-- Placeholder migration for remote 0074_concepts_reference
-- Already applied on remote; kept empty locally for version alignment.

-- Add reference column for '참고' to concepts
alter table if exists public.concepts
  add column if not exists reference text