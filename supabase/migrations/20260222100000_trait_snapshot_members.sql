-- Stable snapshot membership for participant paging (v1.0, v2.0, ...)
-- This migration is non-destructive:
-- - creates membership tables/functions
-- - never rewrites existing memberships
-- - inserts initial members only when the version has no members yet

create table if not exists public.trait_snapshot_versions (
  snapshot_version text primary key,
  cutoff_at timestamptz,
  source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trait_snapshot_members (
  snapshot_version text not null references public.trait_snapshot_versions(snapshot_version) on delete cascade,
  participant_id uuid not null references public.survey_participants(id) on delete cascade,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  primary key (snapshot_version, participant_id)
);

create index if not exists idx_trait_snapshot_members_participant
  on public.trait_snapshot_members(participant_id);

drop trigger if exists set_trait_snapshot_versions_updated_at on public.trait_snapshot_versions;
create trigger set_trait_snapshot_versions_updated_at
before update on public.trait_snapshot_versions
for each row execute function public.set_updated_at();

alter table public.trait_snapshot_versions enable row level security;
alter table public.trait_snapshot_members enable row level security;

drop policy if exists "Admins read trait_snapshot_versions" on public.trait_snapshot_versions;
create policy "Admins read trait_snapshot_versions"
on public.trait_snapshot_versions for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_snapshot_versions" on public.trait_snapshot_versions;
create policy "Admins manage trait_snapshot_versions"
on public.trait_snapshot_versions for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

drop policy if exists "Admins read trait_snapshot_members" on public.trait_snapshot_members;
create policy "Admins read trait_snapshot_members"
on public.trait_snapshot_members for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_snapshot_members" on public.trait_snapshot_members;
create policy "Admins manage trait_snapshot_members"
on public.trait_snapshot_members for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

create or replace function public.ensure_trait_snapshot_members(p_snapshot_version text default 'v1.0')
returns jsonb
language plpgsql security definer
as $$
declare
  v_existing_count int := 0;
  v_inserted int := 0;
  v_cutoff timestamptz;
  v_source text := null;
begin
  select count(*) into v_existing_count
  from public.trait_snapshot_members
  where snapshot_version = p_snapshot_version;

  if v_existing_count > 0 then
    return jsonb_build_object(
      'ok', true,
      'snapshot_version', p_snapshot_version,
      'existing_count', v_existing_count,
      'inserted', 0,
      'reason', 'already_initialized'
    );
  end if;

  select cutoff_at, source
    into v_cutoff, v_source
  from public.trait_snapshot_versions
  where snapshot_version = p_snapshot_version;

  if v_cutoff is null then
    select max(sent_at) into v_cutoff
    from public.trait_report_tokens
    where sent_at is not null;
    if v_cutoff is not null then
      v_source := 'max_report_sent_at';
    end if;
  end if;

  if v_cutoff is null then
    select max(created_at) into v_cutoff
    from public.trait_report_tokens
    where cohort = 'snapshot';
    if v_cutoff is not null then
      v_source := 'legacy_snapshot_cohort_created_at';
    end if;
  end if;

  if v_cutoff is null then
    select max(created_at) into v_cutoff
    from public.trait_report_tokens;
    if v_cutoff is not null then
      v_source := 'fallback_report_token_created_at';
    end if;
  end if;

  insert into public.trait_snapshot_versions (snapshot_version, cutoff_at, source)
  values (p_snapshot_version, v_cutoff, v_source)
  on conflict (snapshot_version) do update
    set cutoff_at = coalesce(public.trait_snapshot_versions.cutoff_at, excluded.cutoff_at),
        source = coalesce(public.trait_snapshot_versions.source, excluded.source),
        updated_at = now();

  if v_cutoff is null then
    return jsonb_build_object(
      'ok', false,
      'snapshot_version', p_snapshot_version,
      'existing_count', 0,
      'inserted', 0,
      'reason', 'no_cutoff_inferred'
    );
  end if;

  insert into public.trait_snapshot_members (snapshot_version, participant_id, source)
  select p_snapshot_version, sp.id, 'auto_cutoff'
  from public.survey_participants sp
  where sp.created_at <= v_cutoff
    and exists (
      select 1
      from public.question_responses qr
      join public.question_answers qa on qa.response_id = qr.id
      join public.questions q on q.id = qa.question_id
      where qr.participant_id = sp.id
        and coalesce((regexp_match(coalesce(q.round_label, ''), '([0-9]+)'))[1]::int, 1) = 1
    )
  on conflict (snapshot_version, participant_id) do nothing;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  return jsonb_build_object(
    'ok', true,
    'snapshot_version', p_snapshot_version,
    'cutoff_at', v_cutoff,
    'source', v_source,
    'existing_count', 0,
    'inserted', v_inserted
  );
end;
$$;

grant execute on function public.ensure_trait_snapshot_members(text) to authenticated;
