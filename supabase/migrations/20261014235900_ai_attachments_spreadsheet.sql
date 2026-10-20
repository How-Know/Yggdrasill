-- Think 엑셀 읽기·분석·파일 생성 (Think 결정 6d0ec9c1).
-- - 운영자는 .xlsx를 첨부할 수 있다.
-- - Think가 파이썬 실행 환경에서 만든 .xlsx·.csv·.png를 같은 비공개 버킷에 저장해 답변에 붙인다.
-- 접근 정책(슈퍼관리자만 읽기·쓰기·삭제)과 크기 한도(20MB)는 그대로 둔다.

update storage.buckets
set allowed_mime_types = array[
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
  'application/pdf',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/csv'
]
where id = 'ai-attachments';
