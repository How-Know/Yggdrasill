-- 사양 5-6: 1-1·1-2 의 예전 개념 태그는 잘못된 후보 목록에서 고른 값이라 근거로 쓰지 않는다(사장님 확인 2026-11-13).
-- 20261113180000 에서 옮긴 메타(confirmed_by 없음)의 개념 태그와 개념 점수를 비우고, 총 난이도를 사고+계산으로 맞춘다.
-- 메타 보충(AI)이 전 문항의 개념 태그를 새로 고르고, 소단원 확정이 그 값으로 이 행을 채운다.
update public.pb_question_meta
   set concept_ids = '{}'::uuid[],
       concept_score = 0,
       total_difficulty = round(thinking_score + arithmetic_score, 2),
       updated_at = now()
 where confirmed_by is null;
