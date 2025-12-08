-- Placeholder migration for remote 0076_concepts_versions
-- Already applied on remote; kept empty locally for version alignment.

-- Add version support to concepts
do $$ begin
  alter table public.concepts add column if not exists family_id uuid;
  alter table public.concepts add column if not exists version_label text not null default '';
exception when duplicate_column then
  null;
end $$
-- Create families for existing distinct names and link concepts
insert into public.concept_families (canonical_name)
select distinct name from public.concepts
where name is not null and length(name) > 0
on conflict (canonical_name) do nothing
update public.concepts c
set family_id = f.id
from public.concept_families f
where c.family_id is null
  and c.name = f.canonical_name
-- Enforce not-null after backfill
alter table public.concepts
  alter column family_id set not null
-- Backfill unique version_label per family to avoid duplicates before unique index
with ranked as (
  select
    id,
    family_id,
    row_number() over (partition by family_id order by created_at nulls first, id) as rn
  from public.concepts
)
update public.concepts c
set version_label = case
  when r.rn = 1 then '기본'
  else '기본-' || r.rn::text
end
from ranked r
where c.id = r.id
  and coalesce(c.version_label, '') = ''
-- Unique family/version combination
do $$ begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'concepts_family_version_unique'
  ) then
    create unique index concepts_family_version_unique on public.concepts (family_id, version_label);
  end if;
end $$