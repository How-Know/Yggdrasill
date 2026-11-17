-- 문항 영역(crop) 삭제 때 crop_id 하나로 찾는 조회용. 설명은 20261116190100 파일 참고.
set lock_timeout = '3s';

create index if not exists idx_student_problem_rounds_crop_id_fk
  on public.student_problem_rounds (crop_id);
