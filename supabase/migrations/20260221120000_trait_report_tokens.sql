create table if not exists trait_report_tokens (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references survey_participants(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  report_params jsonb not null default '{}'::jsonb,
  email text,
  sent_at timestamptz,
  last_send_status text,
  last_send_error text,
  last_message_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_report_token_participant unique (participant_id)
);

create index if not exists idx_trait_report_tokens_token on trait_report_tokens(token);
create index if not exists idx_trait_report_tokens_participant on trait_report_tokens(participant_id);

alter table trait_report_tokens enable row level security;

create policy "anon_read_report_tokens"
  on trait_report_tokens for select
  to anon, authenticated
  using (true);

create policy "service_manage_report_tokens"
  on trait_report_tokens for all
  to service_role
  using (true)
  with check (true);

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
