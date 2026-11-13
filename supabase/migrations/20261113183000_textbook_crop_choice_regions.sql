-- 객관식 문항의 인쇄된 보기 번호(①~⑤) 원문자 좌표를 저장한다.
-- 이미지 스캔 PDF(텍스트 레이어 없음)에서도 원본 보기 PDF 위에 직접 체크 시
-- 보기 번호를 판별할 수 있도록 0~1000 정규화 좌표 {"1":[y1,x1,y2,x2], ...} 로 보관한다.

alter table public.textbook_problem_crops
  add column if not exists choice_regions_1k jsonb;
