-- 20260212103000: add desired level (hope) to student_level_states

alter table public.student_level_states
  add column if not exists desired_level_code smallint;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'chk_student_level_states_desired'
  ) then
    alter table public.student_level_states
      add constraint chk_student_level_states_desired
      check (desired_level_code is null or desired_level_code between 1 and 6);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'fk_student_level_states_desired'
  ) then
    alter table public.student_level_states
      add constraint fk_student_level_states_desired
      foreign key (academy_id, desired_level_code)
      references public.student_level_scales(academy_id, level_code)
      on update cascade
      on delete restrict;
  end if;
end
$$;
