-- 교재 해설 오류를 사장님이 교정한 문항은 원본 해설과 교정본을 둘 다 남긴다(2026-11-16 사장님 결정).
-- 저장 단위는 문항 × 해설 종류 × 버전이다. 종류에 교정본(corrected)을 더한다.
--   original  : 교재에 인쇄된 해설 그대로(오류가 있어도 그대로)
--   corrected : 사장님이 교정한 해설. 교정한 문항에만 있다. 읽는 쪽은 교정본이 있으면 교정본을 쓴다.
-- 정답은 표를 더 만들지 않는다. 교재에 인쇄된 정답은 원본 해설 행의 answer 에, 교정한 채점 정답은 정답 표에 이미 따로 있다.

-- 1) 교정 전 원본 해설 전사. 교정한 문항에만 채워진다.
alter table public.textbook_problem_analyses
  add column if not exists solution_transcribed_original text;

comment on column public.textbook_problem_analyses.solution_transcribed_original is
  '사장님이 교재 해설 오류를 교정하기 전의 원본 해설 전사. 교정한 문항에만 있다.';

-- 2) 해설 종류에 교정본을 더한다.
alter table public.pb_question_solutions
  drop constraint if exists pb_question_solutions_kind_check;
alter table public.pb_question_solutions
  add constraint pb_question_solutions_kind_check check (kind in ('original', 'corrected'));

-- 2-1) 해설 논리 오류 지적에 AI 가 고친 해설(solution_fix)을 수정안으로 달 수 있게 한다. 사장님이 교정할지 그대로 둘지 고른다.
alter table public.textbook_review_findings
  drop constraint if exists textbook_review_findings_proposal_chk;
alter table public.textbook_review_findings
  add constraint textbook_review_findings_proposal_chk check (
    proposal is null
    or (jsonb_typeof(proposal) = 'object'
        and proposal ->> 'target' in ('answer', 'solution_ref', 'correction_note', 'solution_fix'))
  );

-- 3) 교정하기 직전에 원본 해설 전사를 따로 남긴다. 이미 남긴 문항은 건드리지 않는다.
create or replace function public.textbook_review_keep_solution_original(p_crop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kept boolean := false;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  update public.textbook_problem_analyses
     set solution_transcribed_original = solution_transcribed,
         updated_at = now()
   where crop_id = p_crop_id
     and solution_transcribed_original is null
     and btrim(coalesce(solution_transcribed, '')) <> '';
  v_kept := found;
  return jsonb_build_object('ok', true, 'kept', v_kept);
end;
$$;

revoke all on function public.textbook_review_keep_solution_original(uuid) from public, anon;
grant execute on function public.textbook_review_keep_solution_original(uuid) to authenticated;

-- 4) 확정한 해설을 문제은행 문항 쪽에 쓴다(내부용). 교정한 문항은 원본과 교정본을 둘 다 쓴다.
create or replace function public.textbook_review_publish_solutions(p_crop_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_n int := 0;
begin
  for v_row in
    select c.id as crop_id, c.academy_id,
           public.textbook_review_linked_pb_question(c.id) as question_id,
           btrim(coalesce(an.solution_transcribed, '')) as body,
           btrim(coalesce(an.solution_transcribed_original, '')) as original_body,
           btrim(coalesce(an.solution_answer, '')) as answer,
           case when jsonb_typeof(an.solution_figure_assets) = 'array'
                then an.solution_figure_assets else '[]'::jsonb end as figures
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
     where c.id = any (p_crop_ids)
       and not coalesce(c.is_set_header, false)
  loop
    continue when v_row.question_id is null;
    if v_row.body = '' and v_row.answer = '' and jsonb_array_length(v_row.figures) = 0 then
      delete from public.pb_question_solutions
       where question_id = v_row.question_id and kind in ('original', 'corrected');
      continue;
    end if;
    insert into public.pb_question_solutions (
      question_id, kind, version, academy_id, body, answer, figure_assets,
      source_crop_id, confirmed_at, confirmed_by, updated_at
    ) values (
      v_row.question_id, 'original', 1, v_row.academy_id,
      case when v_row.original_body <> '' then v_row.original_body else v_row.body end,
      v_row.answer, v_row.figures,
      v_row.crop_id, now(), auth.uid(), now()
    )
    on conflict (question_id, kind, version) do update
      set academy_id = excluded.academy_id,
          body = excluded.body,
          answer = excluded.answer,
          figure_assets = excluded.figure_assets,
          source_crop_id = excluded.source_crop_id,
          confirmed_at = excluded.confirmed_at,
          confirmed_by = excluded.confirmed_by,
          updated_at = now();
    if v_row.original_body <> '' and v_row.original_body <> v_row.body then
      insert into public.pb_question_solutions (
        question_id, kind, version, academy_id, body, answer, figure_assets,
        source_crop_id, confirmed_at, confirmed_by, updated_at
      ) values (
        v_row.question_id, 'corrected', 1, v_row.academy_id, v_row.body, v_row.answer, v_row.figures,
        v_row.crop_id, now(), auth.uid(), now()
      )
      on conflict (question_id, kind, version) do update
        set academy_id = excluded.academy_id,
            body = excluded.body,
            answer = excluded.answer,
            figure_assets = excluded.figure_assets,
            source_crop_id = excluded.source_crop_id,
            confirmed_at = excluded.confirmed_at,
            confirmed_by = excluded.confirmed_by,
            updated_at = now();
    else
      delete from public.pb_question_solutions
       where question_id = v_row.question_id and kind = 'corrected';
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.textbook_review_publish_solutions(uuid[]) from public, anon, authenticated;

notify pgrst, 'reload schema';
