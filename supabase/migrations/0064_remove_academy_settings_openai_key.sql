-- Remove openai_api_key column from academy_settings table
-- This is now managed in platform_config table

-- Check if column exists before dropping (safe migration)
do $$
begin
  if exists(
    select 1 from information_schema.columns 
    where table_name='academy_settings' and column_name='openai_api_key'
  ) then
    alter table academy_settings drop column openai_api_key;
  end if;
end $$;

-- Comment
comment on table academy_settings is 'Academy-specific settings (excluding global configs like API keys)';



