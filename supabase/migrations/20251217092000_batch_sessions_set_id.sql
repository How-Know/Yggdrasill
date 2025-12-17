alter table public.lesson_batch_sessions
  add column if not exists set_id text,
  add column if not exists session_type_id text;

create index if not exists idx_lesson_batch_sessions_set
  on public.lesson_batch_sessions(set_id);


