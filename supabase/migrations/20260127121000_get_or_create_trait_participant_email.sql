-- Add email support to get_or_create_trait_participant

create or replace function public.get_or_create_trait_participant(
  p_participant_id uuid,
  p_survey_slug text,
  p_client_id text default null,
  p_name text default null,
  p_school text default null,
  p_level text default null,
  p_grade text default null,
  p_email text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_survey_id uuid;
begin
  select s.id into v_survey_id
  from public.surveys s
  where s.slug = p_survey_slug
  limit 1;

  if v_survey_id is null then
    raise exception 'invalid survey slug';
  end if;

  insert into public.survey_participants (id, survey_id, client_id, name, school, grade, level, email)
  values (
    p_participant_id,
    v_survey_id,
    p_client_id,
    coalesce(nullif(p_name, ''), '기존학생'),
    nullif(p_school, ''),
    nullif(p_grade, ''),
    case when p_level in ('elementary','middle','high') then p_level else null end,
    nullif(p_email, '')
  )
  on conflict (id) do update
  set
    -- keep row usable for current survey
    survey_id = excluded.survey_id,
    client_id = coalesce(excluded.client_id, public.survey_participants.client_id),
    name = coalesce(excluded.name, public.survey_participants.name),
    school = coalesce(excluded.school, public.survey_participants.school),
    grade = coalesce(excluded.grade, public.survey_participants.grade),
    level = coalesce(excluded.level, public.survey_participants.level),
    email = coalesce(nullif(excluded.email, ''), public.survey_participants.email);

  return p_participant_id;
end;
$$;

revoke all on function public.get_or_create_trait_participant(uuid, text, text, text, text, text, text, text) from public;
grant execute on function public.get_or_create_trait_participant(uuid, text, text, text, text, text, text, text) to anon, authenticated;

