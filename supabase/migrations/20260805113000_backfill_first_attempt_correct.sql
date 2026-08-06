-- first_attempt_correct 누락 백필.
-- 20260731 컬럼 추가 이후, Edge Function이 필드를 쓰기 전에 채점된 행은
-- DEFAULT false 로 남았고 이후 수정에도 고정되어 정답률 0%가 된다.
--
-- 규칙 (최초 백필과 동일 취지):
--   · 시도 1회 + 현재 정답 → 최초 정답
--   · 시도 2회+ 이지만 first_correct_at 이 생성 직후(5초) → 최초 정답으로 본다
-- 이미 true 인 행·최초 오답이 분명한 행은 건드리지 않는다.

update public.student_textbook_answer_records r
set first_attempt_correct = true
where r.first_attempt_correct = false
  and r.is_correct = true
  and r.attempt_count <= 1;

update public.student_textbook_answer_records r
set first_attempt_correct = true
where r.first_attempt_correct = false
  and r.is_correct = true
  and r.attempt_count > 1
  and r.first_correct_at is not null
  and r.first_correct_at <= r.created_at + interval '5 seconds';
