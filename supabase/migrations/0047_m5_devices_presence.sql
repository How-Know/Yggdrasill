-- m5_devices presence registry
create table if not exists public.m5_devices (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null,
  device_id text not null,
  name text null,
  info jsonb null,
  is_online boolean not null default false,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (academy_id, device_id)
);

alter table public.m5_devices enable row level security;

-- simple read policy (adjust later to academy scoping)
do $$ begin
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'm5_devices' and policyname = 'm5_devices_select'
  ) then
    create policy m5_devices_select on public.m5_devices for select using (true);
  end if;
end $$;

-- upsert presence function
create or replace function public.m5_device_presence(
  p_academy_id uuid,
  p_device_id text,
  p_online boolean,
  p_at timestamptz default now()
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.m5_devices (academy_id, device_id, is_online, last_seen, updated_at)
  values (p_academy_id, p_device_id, p_online, coalesce(p_at, now()), now())
  on conflict (academy_id, device_id)
  do update set is_online = excluded.is_online, last_seen = excluded.last_seen, updated_at = now();
end;
$$;

grant execute on function public.m5_device_presence(uuid, text, boolean, timestamptz) to anon, authenticated;



