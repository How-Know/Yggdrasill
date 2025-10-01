-- Add display_order column to groups and backfill to preserve current UI order
do $$
begin
  -- 1) Add column if not exists
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'groups' and column_name = 'display_order'
  ) then
    alter table public.groups add column display_order integer;
  end if;

  -- 2) Backfill: preserve current visual order (previously sorted by name)
  --    Use name, then created_at, then id for deterministic ordering
  with ordered as (
    select id,
           row_number() over (order by name asc, created_at asc, id asc) - 1 as rn
    from public.groups
  )
  update public.groups g
     set display_order = o.rn
    from ordered o
   where o.id = g.id
     and (g.display_order is null);
end $$;

-- Optional index to speed ordering (small table, but harmless)
create index if not exists idx_groups_display_order on public.groups(display_order asc);


