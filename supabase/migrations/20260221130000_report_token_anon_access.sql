-- RPC: include participant info so anon users (token access) can see it
create or replace function public.get_report_by_token(p_token uuid)
returns jsonb
language plpgsql security definer
as $$
declare
  v_params jsonb;
  v_pid uuid;
  v_participant record;
begin
  select report_params, participant_id into v_params, v_pid
  from trait_report_tokens
  where token = p_token;

  if v_params is null then
    return null;
  end if;

  select id, name, school, grade into v_participant
  from survey_participants
  where id = v_pid;

  if v_participant.id is not null then
    v_params = v_params || jsonb_build_object(
      '_participant', jsonb_build_object(
        'id', v_participant.id,
        'name', v_participant.name,
        'school', v_participant.school,
        'grade', v_participant.grade
      )
    );
  end if;

  return v_params;
end;
$$;

grant execute on function public.get_report_by_token(uuid) to anon, authenticated;

-- Allow anon users to read feedback templates (needed for token-based report view)
drop policy if exists "Anon read trait_feedback_templates" on public.trait_feedback_templates;
create policy "Anon read trait_feedback_templates"
on public.trait_feedback_templates for select
using (true);
