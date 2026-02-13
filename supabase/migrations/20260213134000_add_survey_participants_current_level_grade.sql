alter table if exists public.survey_participants
  add column if not exists current_level_grade smallint;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'survey_participants_current_level_grade_range_ck'
      and conrelid = 'public.survey_participants'::regclass
  ) then
    alter table public.survey_participants
      add constraint survey_participants_current_level_grade_range_ck
      check (
        current_level_grade is null
        or (current_level_grade >= 0 and current_level_grade <= 6)
      );
  end if;
end
$$;

comment on column public.survey_participants.current_level_grade is
  'Current math level grade code (0=top1,1=top4,2=top11,3=top23,4=top40,5=top60,6=below60).';
