-- 20261106231500:
-- 검수 화면의 '② 정답 + 해설' 카드에서 다중 소문항 정답(1)~5)) 사이에 줄바꿈([문단])을 넣지 않고
-- 한 줄로 이어 그려 '정답 줄 가로 넘침' / '정답 줄 오른쪽 잘림'으로 엔진 보류(held)되었던 문항
-- (예: 수력충전 1-1 '2. 문자와 식 › 3. 일차방정식의 활용' 170쪽 02번, 171쪽 03·04번)을
-- 앱의 formatAnswerForCard 줄바꿈 적용에 맞춰 보류 해제 및 품질 승인으로 전환한다.

update public.textbook_problem_analyses an
   set quality_status = 'approved',
       quality_approved_at = coalesce(an.quality_approved_at, now()),
       engine_held_at = null,
       engine_held_by = null,
       engine_hold_note = null,
       engine_resolved_at = now(),
       render_checks = jsonb_set(
         jsonb_set(
           jsonb_set(
             jsonb_set(coalesce(an.render_checks, '{}'::jsonb), '{answer_ok}', 'true'::jsonb, true),
             '{issue_kind}', '"none"'::jsonb, true
           ),
           '{issue_title}', 'null'::jsonb, true
         ),
         '{engine_symptom}', 'null'::jsonb, true
       ) - 'issue_detail',
       updated_at = now()
 where an.quality_status = 'held'
   and coalesce((an.render_checks ->> 'problem_ok')::boolean, true) = true
   and coalesce((an.render_checks ->> 'fidelity_ok')::boolean, true) = true
   and (
     an.engine_hold_note ~ '정답\s*줄.*(잘림|넘침)'
     or coalesce(an.render_checks ->> 'engine_symptom', '') ~ '정답\s*줄.*(잘림|넘침)'
     or coalesce(an.render_checks ->> 'issue_title', '') ~ '정답\s*줄.*(잘림|넘침)'
   );

update public.textbook_review_findings f
   set status = 'resolved',
       resolution = 'auto_cleared',
       resolved_at = now()
  from public.textbook_problem_analyses an
 where f.crop_id = an.crop_id
   and f.status in ('open', 'held')
   and an.quality_status = 'approved';
