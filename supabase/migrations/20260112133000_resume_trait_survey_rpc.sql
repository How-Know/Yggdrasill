-- Resume trait survey for in-app WebView usage.
-- We avoid granting anon SELECT on answer tables by exposing RPCs with SECURITY DEFINER.

-- Ensure one response per participant (so we can resume deterministically)
create unique index if not exists uq_question_responses_participant
on public.question_responses(participant_id)
where participant_id is not null;

-- Create or reuse a question_response for a participant
create or replace function public.get_or_create_trait_response(
  p_participant_id uuid,
  p_client_id text default null,
  p_user_agent text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  out_id uuid;
begin
  insert into public.question_responses (participant_id, client_id, user_agent)
  values (p_participant_id, p_client_id, p_user_agent)
  on conflict (participant_id) do update
  set client_id = excluded.client_id,
      user_agent = excluded.user_agent
  returning id into out_id;
  return out_id;
end;
$$;

revoke all on function public.get_or_create_trait_response(uuid, text, text) from public;
grant execute on function public.get_or_create_trait_response(uuid, text, text) to anon, authenticated;

-- List saved answers for a response (used to resume progress)
create or replace function public.list_trait_answers(
  p_response_id uuid
) returns table (
  question_id uuid,
  answer_number numeric,
  answer_text text
)
language sql
security definer
set search_path = public
as $$
  select qa.question_id, qa.answer_number, qa.answer_text
  from public.question_answers qa
  where qa.response_id = p_response_id;
$$;

revoke all on function public.list_trait_answers(uuid) from public;
grant execute on function public.list_trait_answers(uuid) to anon, authenticated;

