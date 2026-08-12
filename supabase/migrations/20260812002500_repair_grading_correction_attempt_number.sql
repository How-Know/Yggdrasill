-- 일부 원격 환경에서 migration history에는 반영됐지만 PostgREST가
-- correction_attempt_number를 찾지 못해 파트별 채점 조회가 호환 경로로
-- 강등되는 상태를 복구한다.

alter table public.homework_test_grading_attempt_items
  add column if not exists correction_attempt_number integer;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname =
      'hw_test_grading_attempt_items_correction_attempt_number_chk'
      and conrelid =
        'public.homework_test_grading_attempt_items'::regclass
  ) then
    alter table public.homework_test_grading_attempt_items
      add constraint
        hw_test_grading_attempt_items_correction_attempt_number_chk
      check (
        correction_attempt_number is null
        or correction_attempt_number >= 1
      );
  end if;
end;
$$;

notify pgrst, 'reload schema';
