-- 20261104233000:
-- 수력충전 1-1 '0. 소인수분해 › 1. 최대공약수와 최소공배수' 25쪽 01~05번:
-- 1) 25쪽 01번은 개별 발문 첫 줄 수식 '$8,\ 12$' 복원 직후 옛 V2 캐시 이미지로 fix_pass 가 돌아
--    '저장된 개별 발문의 첫 줄 수식 $8,\ 12$가 V2 화면에 표시되지 않습니다.'로 잘못 보류(held)되었으나,
--    실제 V2 재렌더 검수에서 문항 카드가 정상(problem_ok = true, fidelity_ok = true)으로 확인되었으므로
--    보류를 해제하고 품질 승인으로 전환한다.
-- 2) 25쪽 01~05번의 소문항 정답('1) ... 2) ...')이 V2 정답 카드 수식 모드에서 공백이 무시되어
--    '82)', '123)'처럼 붙어 보인다는 render_checks 경고를 정리한다(앱의 formatAnswerForCard 가 [공백:1.5]로 분리 렌더).

update public.textbook_problem_analyses an
   set quality_status = 'approved',
       quality_approved_at = coalesce(an.quality_approved_at, now()),
       engine_held_at = null,
       engine_held_by = null,
       engine_hold_note = null,
       engine_resolved_at = case when an.quality_status = 'held' then now() else an.engine_resolved_at end,
       fix_proposal = jsonb_set(
         jsonb_set(coalesce(an.fix_proposal, '{}'::jsonb), '{kind}', '"none"'::jsonb, true),
         '{engine_issue}', 'null'::jsonb, true
       ),
       render_checks = jsonb_set(
         jsonb_set(
           jsonb_set(
             jsonb_set(coalesce(an.render_checks, '{}'::jsonb), '{problem_ok}', 'true'::jsonb, true),
             '{answer_ok}', 'true'::jsonb, true
           ),
           '{issue_kind}', '"none"'::jsonb, true
         ),
         '{issue_title}', 'null'::jsonb, true
       ) - 'issue_detail',
       updated_at = now()
  from public.textbook_problem_crops c
 where an.crop_id = c.id
   and c.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'
   and c.grade_label = '1-1'
   and c.big_order = 0
   and c.mid_order = 1
   and c.raw_page = 25
   and c.problem_number in ('01', '02', '03', '04', '05');

update public.textbook_review_findings f
   set status = 'resolved',
       resolution = 'auto_cleared',
       resolved_at = now()
  from public.textbook_problem_crops c
 where f.crop_id = c.id
   and c.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'
   and c.grade_label = '1-1'
   and c.big_order = 0
   and c.mid_order = 1
   and f.status in ('open', 'held');
