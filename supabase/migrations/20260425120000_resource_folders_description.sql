-- 20260425120000: resource_folders.description
--
-- The student app's local SQLite schema has stored a `description` on every
-- folder since v0, but the Supabase mirror (added in 0014_w1_tables.sql) never
-- mirrored that column. When the manager-app wizard now registers a new
-- textbook folder on the fly, we want operators to leave the same short note
-- students see in the learning app. Backfilling `null` is fine — every
-- existing row already had an empty description locally.

alter table public.resource_folders
  add column if not exists description text;

comment on column public.resource_folders.description is
  'Optional short note about the folder. Mirrors the description field the '
  'student app already exposes in 자료 → 폴더 편집 and the manager app''s '
  '교재 마이그레이션 → 새 폴더 다이얼로그.';
