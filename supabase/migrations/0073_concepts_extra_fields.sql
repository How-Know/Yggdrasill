-- Placeholder for remote 0073_concepts_extra_fields
-- Already applied on remote; kept empty locally for version alignment.

-- Add example and caution columns to concepts
alter table if exists public.concepts
  add column if not exists example text,
  add column if not exists caution text
