-- Add optional PDF source companion to pb_documents for the VLM pipeline.
-- 기존 HWPX 원본은 유지하고, VLM 추출(PDF 입력)을 위해 PDF 원본을 선택적으로 저장한다.
-- 스토리지는 기존 problem-documents 버킷을 공유한다.

alter table public.pb_documents
  add column if not exists source_pdf_storage_bucket text not null default '',
  add column if not exists source_pdf_storage_path text not null default '',
  add column if not exists source_pdf_filename text not null default '',
  add column if not exists source_pdf_sha256 text not null default '',
  add column if not exists source_pdf_size_bytes bigint not null default 0;

-- VLM 파이프라인에서 PDF 유무로 빠르게 조회하기 위한 부분 인덱스.
create index if not exists idx_pb_documents_pdf_present
  on public.pb_documents (academy_id)
  where source_pdf_storage_path <> '';

comment on column public.pb_documents.source_pdf_storage_bucket is 'VLM 추출용 PDF 원본 버킷 (비어있으면 PDF 미등록).';
comment on column public.pb_documents.source_pdf_storage_path is 'VLM 추출용 PDF 원본 오브젝트 경로.';
comment on column public.pb_documents.source_pdf_filename is 'VLM 추출용 PDF 원본 파일명.';
comment on column public.pb_documents.source_pdf_sha256 is 'VLM 추출용 PDF sha256 해시 (중복 업로드 판별).';
comment on column public.pb_documents.source_pdf_size_bytes is 'VLM 추출용 PDF 파일 바이트 크기.';
