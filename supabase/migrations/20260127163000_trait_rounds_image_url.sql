-- Add image_url to trait_rounds and expose in public list RPC
alter table public.trait_rounds
  add column if not exists image_url text;

drop function if exists public.list_trait_rounds_public();

create or replace function public.list_trait_rounds_public()
returns table (
  id uuid,
  name text,
  description text,
  image_url text,
  order_index int,
  is_active boolean
)
language sql
security definer
set search_path = public
as $$
  select r.id, r.name, r.description, r.image_url, r.order_index, r.is_active
  from public.trait_rounds r
  where r.is_active = true
  order by r.order_index asc, r.created_at asc;
$$;

revoke all on function public.list_trait_rounds_public() from public;
grant execute on function public.list_trait_rounds_public() to anon, authenticated;
