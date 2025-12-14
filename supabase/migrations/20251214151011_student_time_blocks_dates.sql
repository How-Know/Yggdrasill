-- W8: student_time_blocks start/end date 컬럼 추가 (누적 기록용)
alter table if exists public.student_time_blocks
  add column if not exists start_date date default current_date;

alter table if exists public.student_time_blocks
  add column if not exists end_date date;

update public.student_time_blocks
   set start_date = coalesce(start_date, coalesce(block_created_at::date, created_at::date, now()::date))
 where start_date is null;

-- 기본값 제거(명시 입력 강제)
alter table if exists public.student_time_blocks
  alter column start_date drop default;

create index if not exists idx_student_time_blocks_student_start
  on public.student_time_blocks(student_id, start_date);

