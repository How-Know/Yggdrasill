-- Fix: get_or_create_trait_response uses `ON CONFLICT (participant_id)`
-- which requires a non-partial unique index/constraint on participant_id.
-- The previous partial unique index (WHERE participant_id is not null) does not match.

drop index if exists public.uq_question_responses_participant;

-- Unique index allows multiple NULLs by default in Postgres, so this is safe.
create unique index if not exists uq_question_responses_participant
on public.question_responses(participant_id);

