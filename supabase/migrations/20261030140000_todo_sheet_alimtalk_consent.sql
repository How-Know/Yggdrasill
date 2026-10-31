-- 알림장 알림톡은 등하원 동의와 따로 받는다. 기본은 끄고, 테스트 대상만 켠다.

alter table public.student_basic_info
  add column if not exists todo_sheet_alimtalk_consent boolean not null default false;

update public.student_basic_info sbi
set todo_sheet_alimtalk_consent = true
from public.students s
where s.id = sbi.student_id
  and s.academy_id = sbi.academy_id
  and s.name = '감나단';
