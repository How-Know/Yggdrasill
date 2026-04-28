-- Season roadmap entries linked to answer_key_grades by grade_key when available.
create table if not exists public.season_roadmap_entries (
  id text not null,
  academy_id uuid not null references public.academies(id) on delete cascade,
  season_year integer not null,
  season_code text not null check (season_code in ('W', 'S', 'U', 'F')),
  school text,
  education_level integer not null,
  grade integer not null,
  grade_key text,
  course_label_snapshot text not null,
  is_optional boolean not null default false,
  order_index integer not null default 0,
  note text,
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid,
  primary key (academy_id, id)
);

create index if not exists idx_season_roadmap_entries_academy_year
  on public.season_roadmap_entries (academy_id, season_year, season_code);

create index if not exists idx_season_roadmap_entries_lookup
  on public.season_roadmap_entries (
    academy_id,
    season_year,
    season_code,
    school,
    education_level,
    grade
  );

alter table public.season_roadmap_entries enable row level security;

drop trigger if exists trg_season_roadmap_entries_audit
  on public.season_roadmap_entries;
create trigger trg_season_roadmap_entries_audit
before insert or update on public.season_roadmap_entries
for each row execute function public._set_audit_fields();

drop policy if exists season_roadmap_entries_select
  on public.season_roadmap_entries;
create policy season_roadmap_entries_select
on public.season_roadmap_entries for select
using (
  exists (
    select 1 from public.memberships s
    where s.academy_id = season_roadmap_entries.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists season_roadmap_entries_ins
  on public.season_roadmap_entries;
create policy season_roadmap_entries_ins
on public.season_roadmap_entries for insert
with check (
  exists (
    select 1 from public.memberships s
    where s.academy_id = season_roadmap_entries.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists season_roadmap_entries_upd
  on public.season_roadmap_entries;
create policy season_roadmap_entries_upd
on public.season_roadmap_entries for update
using (
  exists (
    select 1 from public.memberships s
    where s.academy_id = season_roadmap_entries.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships s
    where s.academy_id = season_roadmap_entries.academy_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists season_roadmap_entries_del
  on public.season_roadmap_entries;
create policy season_roadmap_entries_del
on public.season_roadmap_entries for delete
using (
  exists (
    select 1 from public.memberships s
    where s.academy_id = season_roadmap_entries.academy_id
      and s.user_id = auth.uid()
  )
);
