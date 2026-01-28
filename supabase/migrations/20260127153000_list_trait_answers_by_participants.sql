-- List trait answers for multiple participants (progress bar)
create or replace function public.list_trait_answers_by_participants(
  p_participant_ids uuid[]
) returns table (
  participant_id uuid,
  question_id uuid
)
language sql
security definer
set search_path = public
as $$
  select r.participant_id, qa.question_id
  from public.question_answers qa
  join public.question_responses r on r.id = qa.response_id
  join public.questions q on q.id = qa.question_id
  where r.participant_id = any(p_participant_ids)
    and q.is_active is true;
$$;

revoke all on function public.list_trait_answers_by_participants(uuid[]) from public;
grant execute on function public.list_trait_answers_by_participants(uuid[]) to anon, authenticated;
