-- Track round2 access links for trait survey

create table if not exists public.trait_round2_links (
  token uuid primary key default gen_random_uuid(),
  participant_id uuid not null references public.survey_participants(id) on delete cascade,
  response_id uuid not null references public.question_responses(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  expires_at timestamptz
);

create unique index if not exists uq_trait_round2_links_participant
on public.trait_round2_links(participant_id);

alter table public.trait_round2_links enable row level security;

drop policy if exists "Admins manage trait_round2_links" on public.trait_round2_links;
create policy "Admins manage trait_round2_links"
on public.trait_round2_links for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

create or replace function public.verify_trait_round2_link(
  p_token uuid
) returns table (
  participant_id uuid,
  response_id uuid,
  email text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select l.participant_id, l.response_id, l.email, l.expires_at
  from public.trait_round2_links l
  where l.token = p_token
    and (l.expires_at is null or l.expires_at > now());
end;
$$;

revoke all on function public.verify_trait_round2_link(uuid) from public;
grant execute on function public.verify_trait_round2_link(uuid) to anon, authenticated;

