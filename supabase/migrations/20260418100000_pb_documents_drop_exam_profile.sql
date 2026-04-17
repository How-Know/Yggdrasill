-- Drop obsolete exam_profile column from pb_documents.
-- 추출 힌트는 워커의 stats.examProfile(휴리스틱 + 추출 결과) 로만 산출하도록 단순화한다.

alter table public.pb_documents
  drop column if exists exam_profile;
