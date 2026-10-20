-- 문제은행 문항의 정답이 바뀌면 그 정답으로 구운 PNG(answer_render_assets)를
-- 무효로 한다. 교재 정답(textbook_answers_invalidate_caches)과 같은 방식이다.
--
-- 학습앱·게이트웨이는 render_error 가 빈 그림만 쓰므로 옛 정답 그림이 바로 빠지고
-- 화면에는 현재 정답 텍스트가 보인다. 게이트웨이 백필(매니저 저장 직후, 열람 시
-- 백그라운드)이 render_error 가 있는 자산을 새 정답으로 다시 굽는다.
--
-- 감시 필드는 게이트웨이 pbAnswerTextForUnifiedRenderKind / pbAnswerUnifiedDescriptors
-- 가 정답 그림을 만들 때 읽는 값들이다.

create or replace function public.pb_questions_invalidate_answer_renders()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.subjective_answer is not distinct from new.subjective_answer
     and old.objective_answer_key is not distinct from new.objective_answer_key
     and old.objective_choices is not distinct from new.objective_choices
     and old.choices is not distinct from new.choices
     and old.question_type is not distinct from new.question_type
     and old.allow_objective is not distinct from new.allow_objective
     and old.allow_subjective is not distinct from new.allow_subjective
     and (old.meta -> 'objective_answer_key')
         is not distinct from (new.meta -> 'objective_answer_key')
     and (old.meta -> 'answer_figure_assets')
         is not distinct from (new.meta -> 'answer_figure_assets')
     and (old.meta -> 'answer_figure_layout')
         is not distinct from (new.meta -> 'answer_figure_layout') then
    return null;
  end if;

  update public.answer_render_assets
     set render_error = 'stale_answer'
   where academy_id = new.academy_id
     and source_kind = 'pb_question'
     and source_id = new.id
     and render_error = '';

  return null;
end;
$$;

drop trigger if exists trg_pb_questions_invalidate_answer_renders
  on public.pb_questions;
create trigger trg_pb_questions_invalidate_answer_renders
  after update on public.pb_questions
  for each row execute function public.pb_questions_invalidate_answer_renders();

-- 트리거 이전에 정답을 고쳐 이미 옛 그림이 된 자산도 같이 무효로 한다.
-- 정답 필드를 고친 수정 이력이 그림을 구운 시각보다 늦으면 옛 정답 그림이다.
update public.answer_render_assets a
   set render_error = 'stale_answer'
 where a.source_kind = 'pb_question'
   and a.render_error = ''
   and exists (
     select 1
       from public.pb_question_revisions r
      where r.question_id = a.source_id
        and r.revised_at > coalesce(a.rendered_at, a.updated_at)
        and r.edited_fields && array[
          'subjective_answer',
          'objective_answer_key',
          'objective_choices',
          'choices',
          'question_type',
          'allow_objective',
          'allow_subjective'
        ]::text[]
   );
