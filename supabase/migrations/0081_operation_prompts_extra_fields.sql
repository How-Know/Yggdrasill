-- Placeholder migration for remote 0081_operation_prompts_extra_fields
-- Already applied on remote; kept empty locally for version alignment.

-- Add example and caution columns to operation_prompts
do $$ begin
  alter table public.operation_prompts add column if not exists example text not null default '';
  alter table public.operation_prompts add column if not exists caution text not null default '';
exception when duplicate_column then
  null;
end $$