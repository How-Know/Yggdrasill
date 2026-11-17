-- 검수용 책 행 삭제 때 book_id 하나로 찾는 조회용. 설명은 20261116190100 파일 참고.
set lock_timeout = '3s';

create index if not exists idx_learning_exposures_book_id_fk
  on public.learning_exposures (book_id);
