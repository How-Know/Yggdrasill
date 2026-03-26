-- pb_questions: 객관식/주관식 이중 출제 저장 구조

alter table public.pb_questions
  add column if not exists allow_objective boolean not null default true,
  add column if not exists allow_subjective boolean not null default true,
  add column if not exists objective_choices jsonb not null default '[]'::jsonb,
  add column if not exists objective_answer_key text not null default '',
  add column if not exists subjective_answer text not null default '',
  add column if not exists objective_generated boolean not null default false;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pb_questions_allow_mode_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_allow_mode_chk
      check (allow_objective or allow_subjective);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pb_questions_objective_choices_array_chk'
  ) then
    alter table public.pb_questions
      add constraint pb_questions_objective_choices_array_chk
      check (jsonb_typeof(objective_choices) = 'array');
  end if;
end $$;

-- Backfill: 기존 객관식은 objective_* 채우고, subjective_answer도 함께 보존
update public.pb_questions
set objective_choices = case
      when jsonb_typeof(choices) = 'array' then choices
      else '[]'::jsonb
    end
where question_type = '객관식'
   or (jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) > 0);

update public.pb_questions
set objective_answer_key = coalesce(
      nullif(trim(objective_answer_key), ''),
      nullif(trim(meta ->> 'answer_key'), ''),
      ''
    );

update public.pb_questions
set subjective_answer = coalesce(
      nullif(trim(subjective_answer), ''),
      nullif(trim(meta ->> 'answer_key'), ''),
      nullif(trim(objective_answer_key), ''),
      ''
    );

create index if not exists idx_pb_questions_allow_objective
  on public.pb_questions (academy_id, allow_objective);

create index if not exists idx_pb_questions_allow_subjective
  on public.pb_questions (academy_id, allow_subjective);
