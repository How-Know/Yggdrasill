-- Track per-question response time and fast answers

alter table public.question_answers
  add column if not exists response_ms integer,
  add column if not exists is_fast boolean,
  add column if not exists answered_at timestamptz not null default now();

drop function if exists public.save_question_answer(uuid, uuid, numeric, text);

create or replace function public.save_question_answer(
  p_response_id uuid,
  p_question_id uuid,
  p_answer_number numeric default null,
  p_answer_text text default null,
  p_response_ms integer default null,
  p_is_fast boolean default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.question_responses r where r.id = p_response_id) then
    raise exception 'invalid response_id';
  end if;

  insert into public.question_answers (
    response_id,
    question_id,
    answer_number,
    answer_text,
    response_ms,
    is_fast,
    answered_at
  )
  values (
    p_response_id,
    p_question_id,
    p_answer_number,
    p_answer_text,
    p_response_ms,
    p_is_fast,
    now()
  )
  on conflict (response_id, question_id) do update
  set answer_number = excluded.answer_number,
      answer_text = excluded.answer_text,
      response_ms = excluded.response_ms,
      is_fast = excluded.is_fast,
      answered_at = now();
end;
$$;

revoke all on function public.save_question_answer(uuid, uuid, numeric, text, integer, boolean) from public;
grant execute on function public.save_question_answer(uuid, uuid, numeric, text, integer, boolean) to anon, authenticated;
