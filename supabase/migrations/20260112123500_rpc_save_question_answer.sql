-- RPC to save question answer reliably from anon/webview.
-- Uses SECURITY DEFINER to avoid RLS issues on question_answers upsert.

create or replace function public.save_question_answer(
  p_response_id uuid,
  p_question_id uuid,
  p_answer_number numeric default null,
  p_answer_text text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.question_responses r where r.id = p_response_id) then
    raise exception 'invalid response_id';
  end if;

  insert into public.question_answers (response_id, question_id, answer_number, answer_text)
  values (p_response_id, p_question_id, p_answer_number, p_answer_text)
  on conflict (response_id, question_id) do update
  set answer_number = excluded.answer_number,
      answer_text = excluded.answer_text;
end;
$$;

revoke all on function public.save_question_answer(uuid, uuid, numeric, text) from public;
grant execute on function public.save_question_answer(uuid, uuid, numeric, text) to anon, authenticated;

