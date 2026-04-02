-- pb_documents status check constraint에 draft_ready, draft_review_required 추가
-- 추출 완료 후 매니저앱에서 검토/업로드 전까지 draft 상태로 유지
alter table public.pb_documents
  drop constraint if exists pb_documents_status_check;

alter table public.pb_documents
  add constraint pb_documents_status_check
    check (status in (
      'uploaded',
      'extract_queued',
      'extracting',
      'draft_review_required',
      'draft_ready',
      'review_required',
      'ready',
      'failed',
      'archived'
    ));
