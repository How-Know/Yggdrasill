-- 20260424120000: resource_files.is_published flag
--
-- Controls whether a textbook is visible in the student app. Default is
-- `true` so every existing book stays visible after the rollout. The
-- manager-side wizard will register new books with `is_published = false`
-- so they stay hidden until the operator flips the switch in the migration
-- pane.

alter table public.resource_files
  add column if not exists is_published boolean not null default true;

create index if not exists resource_files_is_published_idx
  on public.resource_files(academy_id, is_published);

comment on column public.resource_files.is_published is
  'When false, the textbook is hidden from the student app (교재 탭). The manager-app '
  'book-registration wizard sets this to false for newly-registered books; a switch '
  'in the migration pane flips it to true once the book is ready for students.';
