create table if not exists public.pb_live_releases (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  preset_id uuid not null references public.pb_export_presets(id) on delete cascade,
  source_document_ids uuid[] not null default array[]::uuid[],
  template_profile text not null default 'csat',
  paper_size text not null default 'A4',
  active_export_job_id uuid references public.pb_exports(id) on delete set null,
  frozen_export_job_id uuid references public.pb_exports(id) on delete set null,
  policy jsonb not null default jsonb_build_object(
    'applyStatuses',
    jsonb_build_array('assigned', 'in_progress')
  ),
  note text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_pb_live_releases_academy_updated
  on public.pb_live_releases(academy_id, updated_at desc);

create index if not exists idx_pb_live_releases_preset
  on public.pb_live_releases(academy_id, preset_id);

alter table public.pb_live_releases enable row level security;

drop policy if exists pb_live_releases_all on public.pb_live_releases;
create policy pb_live_releases_all on public.pb_live_releases
for all
using (
  exists (
    select 1
      from public.memberships m
     where m.academy_id = pb_live_releases.academy_id
       and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
      from public.memberships m
     where m.academy_id = pb_live_releases.academy_id
       and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_pb_live_releases_audit on public.pb_live_releases;
create trigger trg_pb_live_releases_audit
before insert or update on public.pb_live_releases
for each row execute function public._set_audit_fields();

alter table public.homework_assignments
  add column if not exists live_release_id uuid
    references public.pb_live_releases(id) on delete set null,
  add column if not exists release_export_job_id uuid
    references public.pb_exports(id) on delete set null,
  add column if not exists live_release_locked_at timestamptz;

create index if not exists idx_homework_assignments_live_release
  on public.homework_assignments(academy_id, student_id, status, live_release_id);

create index if not exists idx_homework_assignments_release_export_job
  on public.homework_assignments(academy_id, release_export_job_id);

create or replace function public._homework_assignments_lock_live_release_export()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active_export_job_id uuid;
begin
  if new.live_release_id is null then
    return new;
  end if;

  if new.status = 'completed'
     and coalesce(old.status, '') <> 'completed'
     and new.release_export_job_id is null then
    select lr.active_export_job_id
      into v_active_export_job_id
      from public.pb_live_releases lr
     where lr.id = new.live_release_id
       and lr.academy_id = new.academy_id
     limit 1;

    if v_active_export_job_id is not null then
      new.release_export_job_id = v_active_export_job_id;
      new.live_release_locked_at = coalesce(new.live_release_locked_at, now());
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_homework_assignments_lock_live_release_export
  on public.homework_assignments;
create trigger trg_homework_assignments_lock_live_release_export
before update on public.homework_assignments
for each row execute function public._homework_assignments_lock_live_release_export();
