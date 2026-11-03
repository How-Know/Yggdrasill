-- 기존 정답이 '[image]' 자리표시자여서 1회차 V2 렌더 검수에서 '정답 이미지 대신 자리표시자 노출'로 엔진 보류(held)됐으나,
-- 이후 정답(textbook_problem_answers.answer_text)이 실제 표·텍스트 값으로 채워진 문항(예: 수력충전 1-1 48쪽 16·17번)의 보류를 해제하고 품질 승인으로 전환한다.

update public.textbook_problem_analyses an
   set quality_status = 'approved',
       quality_approved_at = coalesce(an.quality_approved_at, now()),
       engine_held_at = null,
       engine_held_by = null,
       engine_hold_note = null,
       render_checks = jsonb_set(
         jsonb_set(
           jsonb_set(
             jsonb_set(coalesce(an.render_checks, '{}'::jsonb), '{answer_ok}', 'true'::jsonb, true),
             '{issue_kind}', '"none"'::jsonb, true
           ),
           '{issue_title}', 'null'::jsonb, true
         ),
         '{issue_detail}', 'null'::jsonb, true
       ),
       updated_at = now()
  from public.textbook_problem_answers a
 where a.crop_id = an.crop_id
   and an.quality_status = 'held'
   and an.engine_hold_note = '정답 이미지 대신 자리표시자 노출'
   and coalesce(btrim(a.answer_text), '') <> ''
   and btrim(a.answer_text) !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$';

update public.textbook_review_findings f
   set status = 'resolved',
       resolution = 'auto_cleared',
       resolved_at = now()
  from public.textbook_problem_analyses an
 where f.crop_id = an.crop_id
   and f.check_key = 'ai_v2_render_student_view'
   and f.title = '정답 이미지 대신 자리표시자 노출'
   and f.status in ('open', 'held')
   and an.quality_status = 'approved';
