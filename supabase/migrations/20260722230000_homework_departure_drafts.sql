-- Session-scoped homework departure drafts.
--
-- A saved draft is distinguished from "no draft" by saved_at:
--   saved_at is null     -> use the legacy default (all eligible groups)
--   saved_at is not null -> use group_ids exactly, including an empty array

alter table public.attendance_records
  add column if not exists homework_draft_group_ids uuid[] not null
    default '{}'::uuid[],
  add column if not exists homework_draft_saved_at timestamptz;

comment on column public.attendance_records.homework_draft_group_ids is
  'Group ids selected for homework when this attendance session checks out.';

comment on column public.attendance_records.homework_draft_saved_at is
  'Non-null means a departure homework draft was explicitly saved, even when group_ids is empty.';

-- Remove the legacy reserved-homework inventory selected by the user for
-- retirement. Preserve an item if it has any non-reservation assignment.
create temporary table legacy_reserved_homework_items on commit drop as
select distinct a.homework_item_id as item_id
from public.homework_assignments a
where coalesce(a.note, '') = '__reserved_homework__'
  and not exists (
    select 1
    from public.homework_assignments other
    where other.homework_item_id = a.homework_item_id
      and coalesce(other.note, '') <> '__reserved_homework__'
  );

create temporary table legacy_reserved_homework_groups on commit drop as
select distinct a.group_id
from public.homework_assignments a
where coalesce(a.note, '') = '__reserved_homework__'
  and a.group_id is not null;

delete from public.homework_assignments
where coalesce(note, '') = '__reserved_homework__';

delete from public.homework_items h
where h.id in (
  select item_id
  from legacy_reserved_homework_items
);

delete from public.homework_groups g
where g.id in (
  select group_id
  from legacy_reserved_homework_groups
)
and not exists (
  select 1
  from public.homework_group_items gi
  where gi.group_id = g.id
);

drop function if exists public.homework_create_reserved_homework_bundle(
  uuid,
  uuid,
  jsonb,
  jsonb
);
