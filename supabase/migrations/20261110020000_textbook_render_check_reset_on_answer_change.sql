-- 정답·해설이 바뀌면 V2 렌더 검수(정답·해설 카드 대조)를 다시 하도록 검수 시각을 지운다.
-- 판정 내용(render_checks)은 다시 대조할 때까지 남겨 둔다.

create or replace function public.textbook_answer_reset_render_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT'
     or (old.answer_text, old.answer_latex_2d, old.answer_image_path)
        is distinct from (new.answer_text, new.answer_latex_2d, new.answer_image_path) then
    update public.textbook_problem_analyses
       set render_checked_at = null
     where crop_id = new.crop_id
       and render_checked_at is not null;
  end if;
  return new;
end;
$$;

drop trigger if exists textbook_answer_reset_render_check on public.textbook_problem_answers;
create trigger textbook_answer_reset_render_check
  after insert or update on public.textbook_problem_answers
  for each row execute function public.textbook_answer_reset_render_check();

create or replace function public.textbook_solution_reset_render_check()
returns trigger
language plpgsql
as $$
begin
  if old.solution_transcribed is distinct from new.solution_transcribed
     or (old.ai_solution is distinct from new.ai_solution
         and btrim(coalesce(new.solution_transcribed, '')) = '') then
    new.render_checked_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists textbook_solution_reset_render_check on public.textbook_problem_analyses;
create trigger textbook_solution_reset_render_check
  before update on public.textbook_problem_analyses
  for each row execute function public.textbook_solution_reset_render_check();
