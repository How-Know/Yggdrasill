-- 렌더 검수 뒤에 해설·정답이 바뀌었는데 검수 시각이 남아 있는 문항(트리거 20261110020000 이전에 바뀐 문항)은
-- 다음 검수 때 바뀐 카드로 다시 대조하도록 검수 시각을 지운다. 판정 내용(render_checks)은 남긴다.

update public.textbook_problem_analyses an
   set render_checked_at = null
 where an.render_checked_at is not null
   and (
     an.solution_extracted_at > an.render_checked_at + interval '1 second'
     or exists (
       select 1
         from public.textbook_problem_answers a
        where a.crop_id = an.crop_id
          and a.edited_at > an.render_checked_at + interval '1 second'
     )
   );

-- P190-04: 해설에 [그림] 이 있는데 해설 그림이 저장되지 않았다. 다음 검수 때 해설 그림 찾기를 다시 하게 한다.
update public.textbook_problem_analyses
   set solution_figures_checked_at = null
 where crop_id = 'f94d0872-d39f-4e38-bdc9-52ad3a18f385'
   and coalesce(jsonb_array_length(solution_figure_assets), 0) = 0;
