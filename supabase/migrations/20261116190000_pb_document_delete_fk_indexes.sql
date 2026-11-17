-- 문제은행 문서를 지우면 문항·추출 작업이 함께 지워지고(ON DELETE CASCADE / SET NULL),
-- 그때마다 아래 열 하나만으로 딸린 행을 찾는다. academy_id 로 시작하는 인덱스는 이 조회에
-- 쓰이지 못해 표 전체를 읽는다. 21문항 시험지 한 부를 지우는 데 5초가 걸렸고(한도 8초),
-- 캐시가 식어 있으면 statement_timeout(57014)으로 실패한다.
-- 같은 종류의 문제: 20260928233000_student_delete_fk_student_id_indexes.sql
--
-- 잠금을 오래 기다리지 않는다(못 잡으면 실패하고 다시 적용하면 된다).
set lock_timeout = '3s';

-- 추출 작업 하나가 지워질 때
create index if not exists idx_pb_question_revisions_extract_job_id_fk
  on public.pb_question_revisions (extract_job_id);

create index if not exists idx_pb_questions_extract_job_id_fk
  on public.pb_questions (extract_job_id);

-- 문서 하나가 지워질 때
create index if not exists idx_pb_delivery_units_source_document_id_fk
  on public.pb_delivery_units (source_document_id);

-- 문항 하나가 지워질 때
create index if not exists idx_pb_delivery_units_question_id_fk
  on public.pb_delivery_units (question_id);

create index if not exists idx_pb_question_set_items_question_id_fk
  on public.pb_question_set_items (question_id);

-- 교재·시험지 문항 영역(crop) 하나가 지워질 때
create index if not exists idx_pb_question_meta_source_crop_id_fk
  on public.pb_question_meta (source_crop_id);

create index if not exists idx_question_render_assets_crop_id_fk
  on public.question_render_assets (crop_id);

create index if not exists idx_question_render_jobs_crop_id_fk
  on public.question_render_jobs (crop_id);

create index if not exists idx_question_render_jobs_pb_question_id_fk
  on public.question_render_jobs (pb_question_id);
