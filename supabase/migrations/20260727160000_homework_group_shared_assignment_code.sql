-- 그룹 과제는 하위 항목이 동일한 assignment_code 를 공유할 수 있어야 한다.
-- (기존: academy_id + assignment_code UNIQUE → 하위과제마다 코드가 갈라짐)

drop index if exists public.homework_items_academy_assignment_code_uidx;

-- 검색용 non-unique 인덱스는 유지/재생성
create index if not exists homework_items_assignment_code_idx
  on public.homework_items (assignment_code);

create index if not exists homework_items_academy_assignment_code_idx
  on public.homework_items (academy_id, assignment_code)
  where assignment_code is not null;
