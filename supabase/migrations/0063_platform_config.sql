-- Platform configuration table for storing global settings like API keys
create table if not exists platform_config (
  config_key text primary key,
  config_value text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- RLS policies (authenticated users can access - admin check done in app)
alter table platform_config enable row level security;

-- Allow authenticated users to read platform config
create policy "Authenticated users can read platform config"
  on platform_config for select
  using (auth.role() = 'authenticated');

-- Allow authenticated users to upsert platform config
create policy "Authenticated users can upsert platform config"
  on platform_config for all
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- Trigger to update updated_at
create trigger set_platform_config_updated_at
  before update on platform_config
  for each row
  execute function set_updated_at();

-- Insert OpenAI API key placeholder
insert into platform_config (config_key, config_value)
values ('openai_api_key', '')
on conflict (config_key) do nothing;

-- Comment
comment on table platform_config is 'Platform-wide configuration settings (API keys, global settings)';

