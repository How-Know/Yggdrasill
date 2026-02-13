-- 20260213110000: add textbook_type to textbook_metadata

alter table public.textbook_metadata
  add column if not exists textbook_type text;

alter table public.textbook_metadata
  drop constraint if exists chk_textbook_metadata_textbook_type;

alter table public.textbook_metadata
  add constraint chk_textbook_metadata_textbook_type
  check (
    textbook_type is null
    or textbook_type in ('개념서', '문제집')
  );
