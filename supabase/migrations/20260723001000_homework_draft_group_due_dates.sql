alter table public.attendance_records
  add column if not exists homework_draft_group_due_dates jsonb not null
    default '{}'::jsonb;

comment on column public.attendance_records.homework_draft_group_due_dates is
  'ISO-8601 due timestamp by selected homework group id for this attendance session.';
