-- 모의고사 문항: 시험지 쪽에서 선지 번호(①~⑤) 글자가 놓인 영역.
-- 검수 준비(게이트웨이 prepareMockReview)가 시험지 PDF 글자 층에서 읽어 채운다.
-- 정합성 점검(ai_think textbook_problem_consistency)이 이 영역과 그림 자리를 견줘,
-- 그림이 선지 아래에 있는 문항의 그림 배치를 'below-choices'(본문 → 선지 → 그림)로 맞춘다.
-- 설계: docs/architecture/mock-exam.md

alter table public.mock_exam_items
  add column if not exists choice_number_region_1k int[];

comment on column public.mock_exam_items.choice_number_region_1k is
  '시험지 쪽 기준 선지 번호(①~⑤) 글자를 감싸는 영역 [ymin, xmin, ymax, xmax] (0..1000). 선지가 없거나 글자 층에서 읽지 못하면 null.';
