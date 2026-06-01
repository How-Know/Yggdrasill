-- 추가 숙제 검사(자의로 미리 해온 숙제)를 assignment 생성 없이 임시 기록하기 위한 컬럼.
--
-- Background: 기존 추가검사 흐름은 dueDate=today + __self_extra_check__ 마커로
-- homework_assignments 행을 만들어 버려, 미리 해온 숙제가 "오늘 검사받아야 하는"
-- 정규 과제처럼 취급되는 문제가 있었다.
--
-- 이제 추가검사 시 assignment를 만들지 않고 homework_items에 미리 해온 진행률만
-- 임시로 기록한다. 이후 하원/수동으로 숙제를 내줄 때(assignment 생성) 이 값을
-- 검사 기록으로 소비하고 컬럼을 비운다.

alter table public.homework_items
  add column if not exists pre_done_progress integer,
  add column if not exists pre_done_at timestamptz,
  add column if not exists pre_done_issue_type text,
  add column if not exists pre_done_issue_note text;
