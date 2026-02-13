alter table if exists public.survey_participants
  add column if not exists current_math_percentile numeric(5,2);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'survey_participants_current_math_percentile_range_ck'
      and conrelid = 'public.survey_participants'::regclass
  ) then
    alter table public.survey_participants
      add constraint survey_participants_current_math_percentile_range_ck
      check (
        current_math_percentile is null
        or (current_math_percentile >= 0 and current_math_percentile <= 100)
      );
  end if;
end
$$;

comment on column public.survey_participants.current_math_percentile is
  'Math percentile (0-100, lower is higher rank; 1 means top 1 percent).';
