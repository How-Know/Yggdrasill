-- Add round/part fields to questions and expose public round metadata for survey flow.

alter table public.questions
  add column if not exists round_label text,
  add column if not exists part_index integer;

create or replace function public.list_trait_rounds_public()
returns table (
  id uuid,
  name text,
  description text,
  order_index int,
  is_active boolean
)
language sql
security definer
set search_path = public
as $$
  select r.id, r.name, r.description, r.order_index, r.is_active
  from public.trait_rounds r
  where r.is_active = true
  order by r.order_index asc, r.created_at asc;
$$;

revoke all on function public.list_trait_rounds_public() from public;
grant execute on function public.list_trait_rounds_public() to anon, authenticated;

create or replace function public.list_trait_round_parts_public()
returns table (
  id uuid,
  round_id uuid,
  name text,
  description text,
  image_url text,
  order_index int
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.round_id, p.name, p.description, p.image_url, p.order_index
  from public.trait_round_parts p
  join public.trait_rounds r on r.id = p.round_id
  where r.is_active = true
  order by r.order_index asc, p.order_index asc, p.created_at asc;
$$;

revoke all on function public.list_trait_round_parts_public() from public;
grant execute on function public.list_trait_round_parts_public() to anon, authenticated;
