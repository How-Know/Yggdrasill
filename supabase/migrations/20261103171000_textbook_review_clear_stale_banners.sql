-- 20261103171000: 문항검수 — 이미 수정 적용·원본 대조 통과된 문항의 옛 2단계 배너(quality_checks.issue_title) 및 빈칸형 오판 정리

do $$
declare
  r record;
  v_rem_banners int;
begin
  for r in
    select c.id as crop_id,
           c.problem_number,
           c.raw_page,
           an.quality_status,
           an.quality_checks ->> 'issue_title' as qc_title,
           an.quality_checks ->> 'issue_detail' as qc_detail,
           an.render_checks ->> 'issue_title' as rc_title,
           an.render_checks ->> 'issue_detail' as rc_detail,
           coalesce((an.render_checks ->> 'flagged_after_approval')::boolean, false) as flagged,
           pq.stem,
           coalesce(pq.meta -> 'set_model' ->> 'common_stem', '') as common_stem,
           an.fix_proposal
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      left join public.pb_questions pq on pq.id = public.textbook_review_linked_pb_question(c.id)
     where not c.is_set_header
       and (
         coalesce((an.render_checks ->> 'flagged_after_approval')::boolean, false)
         or an.render_checks ->> 'issue_title' is not null
         or (an.quality_checks ->> 'issue_title' is not null and an.quality_status <> 'held')
       )
     order by c.raw_page, length(c.problem_number), c.problem_number
  loop
    raise notice '[BANNER_BEFORE] #% (p.%): qual=% flagged=% qc_title=[%] rc_title=[%] common=[%] stem=[%]',
      r.problem_number, r.raw_page, r.quality_status, r.flagged,
      coalesce(r.qc_title, ''), coalesce(r.rc_title, ''),
      left(r.common_stem, 60), left(replace(coalesce(r.stem, ''), E'\n', ' '), 80);
  end loop;

  -- 이미 품질 승인(approved)되었고 수정안이 적용되었거나 원본 대조에서 통과한 문항의 옛 quality_checks/render_checks 배너 정리
  update public.textbook_problem_analyses an
     set quality_checks = coalesce(an.quality_checks, '{}'::jsonb)
           || jsonb_build_object(
             'stem_ok', true,
             'choices_ok', true,
             'figure_ok', true,
             'latex_v2_ok', true,
             'fidelity_ok', true,
             'issue_title', null,
             'issue_detail', null
           ),
         render_checks = case
           when jsonb_typeof(an.render_checks) = 'object' and an.render_checks <> '{}'::jsonb
             then an.render_checks || jsonb_build_object(
               'problem_ok', true,
               'answer_ok', true,
               'solution_ok', true,
               'fidelity_ok', true,
               'figure_position_ok', true,
               'flagged_after_approval', false,
               'issue_title', null,
               'issue_detail', null
             )
           else an.render_checks
         end
   where an.quality_status = 'approved';

  select count(*) filter (
           where coalesce((an.render_checks ->> 'flagged_after_approval')::boolean, false)
              or an.render_checks ->> 'issue_title' is not null
              or (an.quality_checks ->> 'issue_title' is not null and an.quality_status <> 'held')
         )::int
    into v_rem_banners
    from public.textbook_problem_crops c
    join public.textbook_problem_analyses an on an.crop_id = c.id
   where not c.is_set_header;

  raise notice '[BANNER_AFTER] remaining_banners=%', v_rem_banners;
end;
$$;
