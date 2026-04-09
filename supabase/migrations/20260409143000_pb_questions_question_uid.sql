alter table public.pb_questions
add column if not exists question_uid uuid;

update public.pb_questions
set question_uid = id
where question_uid is null;

alter table public.pb_questions
alter column question_uid set default gen_random_uuid();

alter table public.pb_questions
alter column question_uid set not null;

create unique index if not exists idx_pb_questions_academy_question_uid
  on public.pb_questions (academy_id, question_uid);
