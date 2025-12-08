-- Placeholder migration for remote 0077_concepts_symbol
-- Already applied on remote; kept empty locally for version alignment.

-- Add optional symbol field to concepts for math symbol notation
alter table public.concepts
  add column if not exists symbol text