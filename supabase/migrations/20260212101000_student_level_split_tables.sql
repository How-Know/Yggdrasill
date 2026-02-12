-- 20260212101000: split student level into dedicated tables

create table if not exists public.student_level_scales (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  level_code smallint not null,
  display_name text not null,
  upper_percent numeric(6, 3) not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint chk_student_level_scales_level_code
    check (level_code between 1 and 6),
  constraint chk_student_level_scales_upper_percent
    check (upper_percent > 0 and upper_percent <= 100)
);

create unique index if not exists uidx_student_level_scales_academy_level
  on public.student_level_scales(academy_id, level_code);
create index if not exists idx_student_level_scales_academy
  on public.student_level_scales(academy_id);

alter table public.student_level_scales enable row level security;
drop policy if exists student_level_scales_all on public.student_level_scales;
create policy student_level_scales_all
on public.student_level_scales
for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_level_scales.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_level_scales.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_student_level_scales_audit on public.student_level_scales;
create trigger trg_student_level_scales_audit
before insert or update on public.student_level_scales
for each row execute function public._set_audit_fields();

insert into public.student_level_scales (
  academy_id,
  level_code,
  display_name,
  upper_percent
)
select
  a.id,
  v.level_code,
  v.display_name,
  v.upper_percent
from public.academies a
cross join (
  values
    (1::smallint, '1등급'::text, 4.0::numeric),
    (2::smallint, '2등급'::text, 11.0::numeric),
    (3::smallint, '3등급'::text, 23.0::numeric),
    (4::smallint, '4등급'::text, 40.0::numeric),
    (5::smallint, '5등급'::text, 60.0::numeric),
    (6::smallint, '6등급'::text, 100.0::numeric)
) as v(level_code, display_name, upper_percent)
on conflict (academy_id, level_code) do nothing;

create table if not exists public.student_level_states (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  current_level_code smallint,
  target_level_code smallint,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint chk_student_level_states_current
    check (current_level_code is null or current_level_code between 1 and 6),
  constraint chk_student_level_states_target
    check (target_level_code is null or target_level_code between 1 and 6),
  constraint fk_student_level_states_current
    foreign key (academy_id, current_level_code)
      references public.student_level_scales(academy_id, level_code)
      on update cascade
      on delete restrict,
  constraint fk_student_level_states_target
    foreign key (academy_id, target_level_code)
      references public.student_level_scales(academy_id, level_code)
      on update cascade
      on delete restrict
);

create unique index if not exists uidx_student_level_states_academy_student
  on public.student_level_states(academy_id, student_id);
create index if not exists idx_student_level_states_student
  on public.student_level_states(student_id);

alter table public.student_level_states enable row level security;
drop policy if exists student_level_states_all on public.student_level_states;
create policy student_level_states_all
on public.student_level_states
for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_level_states.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_level_states.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_student_level_states_audit on public.student_level_states;
create trigger trg_student_level_states_audit
before insert or update on public.student_level_states
for each row execute function public._set_audit_fields();

