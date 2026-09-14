-- Separate student visibility from manager review progress.
-- Existing and newly extracted questions remain visible by default.

alter table public.pb_questions
  add column if not exists is_published boolean not null default true;

create index if not exists pb_questions_academy_published_document_idx
  on public.pb_questions (academy_id, is_published, document_id);

comment on column public.pb_questions.is_published is
  'Controls whether this question is available to learning/student flows. '
  'Independent from is_checked, which records manager review progress.';
