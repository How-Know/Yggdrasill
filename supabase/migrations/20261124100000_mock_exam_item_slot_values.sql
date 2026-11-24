-- 같은 문항은 문제은행 문항(pb_questions) 하나로 두고, 시험지마다 다른 값은 실린 자리(mock_exam_items)에 둔다
-- (사장님 결정 2026-11-24). 가형·나형에 같이 실린 문항은 한 구간만 문항을 갖고, 다른 구간의 자리는
-- pb_question_id 로 그 문항을 가리킨다. 설계: docs/architecture/mock-exam.md "One question, many slots".
--
-- 자리 값은 문항의 값과 다를 때만 적는다. 비어 있으면 문항의 값을 그대로 쓴다.
--   score          : 이 시험지의 배점. 비어 있으면 pb_questions.meta.score_point.
--                    (열은 전부터 있었고 지금까지 쓰이지 않았다. 전 회차 1,440 자리가 비어 있다.)
--   choice_order   : 이 시험지의 선지 순서. i번째 값이 "이 시험지의 i번 선지 = 문항의 몇 번 선지" 다.
--                    순서가 반대면 {5,4,3,2,1}. 비어 있으면 문항의 순서.
--   stem_override  : 이 시험지에 인쇄된 본문. 객관식 시험지는 "…의 값은?", 주관식 시험지는
--                    "…의 값을 구하시오." 처럼 끝 문장이 다른 쌍에만 적는다. 비어 있으면 문항의 본문.
--   merged_at      : 이 자리의 문항을 다른 구간의 문항으로 합친 시각. 비어 있으면 자기 구간의 문항이다.
-- 번호(problem_number), 형식(answer_kind), 정답 표기(answer_text)는 전부터 자리마다 있다.

alter table public.mock_exam_items
  add column if not exists choice_order smallint[],
  add column if not exists stem_override text,
  add column if not exists merged_at timestamptz;

alter table public.mock_exam_items
  drop constraint if exists mock_exam_items_choice_order_check;
alter table public.mock_exam_items
  add constraint mock_exam_items_choice_order_check
    check (choice_order is null or cardinality(choice_order) between 2 and 9);

comment on column public.mock_exam_items.score is
  '이 시험지의 배점. 비어 있으면 pb_questions.meta.score_point 를 쓴다.';
comment on column public.mock_exam_items.choice_order is
  '이 시험지의 선지 순서(i번째 값 = 문항의 몇 번 선지). 비어 있으면 문항의 순서.';
comment on column public.mock_exam_items.stem_override is
  '이 시험지에 인쇄된 본문이 문항의 본문과 다를 때만 적는다.';
comment on column public.mock_exam_items.merged_at is
  '다른 구간의 문항으로 합친 시각. 비어 있으면 자기 구간의 문항.';
