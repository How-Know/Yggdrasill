-- Add extended columns for resource_files used by the client.
alter table if exists public.resource_files
  add column if not exists color integer,
  add column if not exists text_color integer,
  add column if not exists icon_code integer,
  add column if not exists icon_image_path text,
  add column if not exists description text,
  add column if not exists grade text,
  add column if not exists pos_x real,
  add column if not exists pos_y real,
  add column if not exists width real,
  add column if not exists height real;
